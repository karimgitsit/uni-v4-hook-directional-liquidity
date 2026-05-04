// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {BaseHook} from "@openzeppelin/uniswap-hooks/src/base/BaseHook.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {ModifyLiquidityParams, SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {IERC20Minimal} from "@uniswap/v4-core/src/interfaces/external/IERC20Minimal.sol";
import {Position} from "@uniswap/v4-core/src/libraries/Position.sol";
import {LiquidityAmounts} from "@uniswap/v4-periphery/src/libraries/LiquidityAmounts.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";

import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import {ShareMath} from "./libraries/ShareMath.sol";
import {ModeRange} from "./libraries/ModeRange.sol";

/// @title DirectionalLiquidityHook
/// @notice Uniswap v4 hook that ports Maverick AMM's directional liquidity modes
///         (Right / Left / Both) onto v4. One hook contract per pool. LPs hold
///         ERC-721 NFTs minted by this hook. Underlying v4 positions are owned
///         exclusively by the hook; LPs interact through `deposit` / `withdraw`.
/// @dev    See `spec/DirectionalLiquidityHook-spec.md` for the authoritative
///         design. This file is the step-1 skeleton: constructor, immutables,
///         permissions, entry-point stubs, and a no-op `_afterSwap`.
contract DirectionalLiquidityHook is BaseHook, ERC721, ReentrancyGuard, IUnlockCallback {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    // -------------------------------------------------------------------- //
    // Errors                                                               //
    // -------------------------------------------------------------------- //

    /// @notice Thrown by step-1 stubs that have no implementation yet.
    error NotImplemented();

    /// @notice Thrown when an external party tries to add or remove liquidity
    ///         on the underlying v4 pool. All position management must go
    ///         through this hook's `deposit` / `withdraw` flow.
    error DirectLiquidityModificationDisabled();

    /// @notice Thrown when a callback receives a `PoolKey` that is not the
    ///         pool this hook was deployed for.
    error WrongPool();

    /// @notice Thrown by `getTwap()` when the buffer has no observations yet.
    error NoObservations();

    /// @notice Thrown when `unlockCallback` is invoked by anyone other than
    ///         the configured `poolManager`.
    error NotPoolManagerUnlock();

    /// @notice Thrown when `unlockCallback` decodes an action id this
    ///         contract doesn't support.
    error UnknownAction();

    /// @notice Thrown when `deposit` is called with a `mode` outside the
    ///         valid range [0, MODE_COUNT).
    error InvalidMode();

    /// @notice Thrown when `deposit` is called with `liquidity == 0`.
    error ZeroLiquidity();

    /// @notice Thrown when `unlockCallback` ends up with a positive caller
    ///         delta on a deposit (the hook would be paid by the pool —
    ///         shouldn't happen for an add-liquidity action).
    error UnexpectedPositiveDelta();

    /// @notice Thrown by `withdraw` when the caller is not the NFT owner
    ///         (and not approved).
    error NotPositionOwner();

    /// @notice Thrown by `_doWithdraw` if `modifyLiquidity` returns negative
    ///         principal (the hook would owe the pool — shouldn't happen
    ///         for a remove-liquidity action).
    error UnexpectedNegativePrincipal();

    /// @notice Thrown by `rebalance()` when no mode is initialized AND
    ///         needs shifting. Keeper paid gas for nothing — no state change.
    error NothingToRebalance();

    /// @notice Thrown by `deposit` when the post-unlock native-ETH refund
    ///         to the payer fails (e.g. payer is a contract that reverts
    ///         on receive). Surfaces an explicit error rather than
    ///         silently retaining the overpayment.
    error RefundFailed();

    // -------------------------------------------------------------------- //
    // Mode identifiers                                                     //
    // -------------------------------------------------------------------- //

    /// @dev Mode-Right id; position sits one bin LEFT of price.
    uint8 internal constant MODE_RIGHT = ModeRange.MODE_RIGHT;
    /// @dev Mode-Left id; position sits one bin RIGHT of price.
    uint8 internal constant MODE_LEFT = ModeRange.MODE_LEFT;
    /// @dev Mode-Both id; position sits one bin behind the most recent
    ///      price move (tracked via `lastShiftDir`).
    uint8 internal constant MODE_BOTH = ModeRange.MODE_BOTH;
    /// @dev Total number of valid modes; valid mode ids are `[0, MODE_COUNT)`.
    uint8 internal constant MODE_COUNT = 3;

    // -------------------------------------------------------------------- //
    // Unlock callback action ids                                           //
    // -------------------------------------------------------------------- //

    /// @dev `unlockCallback` payload tag for the deposit path.
    uint8 internal constant ACTION_DEPOSIT = 1;
    /// @dev `unlockCallback` payload tag for the withdraw path.
    uint8 internal constant ACTION_WITHDRAW = 2;
    /// @dev `unlockCallback` payload tag for the rebalance path.
    uint8 internal constant ACTION_REBALANCE = 3;

    /// @dev Payload routed through `poolManager.unlock` for a deposit.
    /// @param mode      Mode id `[0, MODE_COUNT)`.
    /// @param liquidity v4 liquidity units to add.
    /// @param payer     Funds the deposit (msg.sender of `deposit`).
    /// @param recipient Receives the LP NFT.
    struct DepositCallbackData {
        uint8 mode;
        uint128 liquidity;
        address payer;
        address recipient;
    }

    /// @dev What `_doDeposit` returns, abi-encoded back through `unlock`.
    /// @param tokenId      Newly-minted LP NFT id.
    /// @param rangeLower   Lower tick the position landed in.
    /// @param rangeUpper   Upper tick the position landed in.
    /// @param sharesIssued Per-mode share count issued to `recipient`.
    /// @param nativeSpent  Amount of native ETH actually pulled from the
    ///                     payer (zero when neither pool currency is native
    ///                     or when the deposit's principal lands in
    ///                     currency1). Used by `deposit` to refund any
    ///                     `msg.value` overpayment back to the payer.
    struct DepositResult {
        uint256 tokenId;
        int24 rangeLower;
        int24 rangeUpper;
        uint128 sharesIssued;
        uint256 nativeSpent;
    }

    /// @dev Payload routed through `poolManager.unlock` for a withdrawal.
    /// @param tokenId   LP NFT id to burn.
    /// @param recipient Receives the principal + fee share.
    struct WithdrawCallbackData {
        uint256 tokenId;
        address recipient;
    }

    /// @dev What `_doWithdraw` returns, abi-encoded back through `unlock`.
    /// @param amount0 Currency0 paid to the recipient (principal + fee share).
    /// @param amount1 Currency1 paid to the recipient.
    struct WithdrawResult {
        uint256 amount0;
        uint256 amount1;
    }

    /// @dev Payload routed through `poolManager.unlock` for a rebalance.
    /// @param  shouldShift  Per-mode flag (index = mode id) — true if this
    ///         mode's TWAP trigger fired and it should burn-and-remint.
    /// @param  newLower     Per-mode new range lower (only valid where
    ///         `shouldShift[i]` is true).
    /// @param  newUpper     Per-mode new range upper.
    /// @param  newDir       Per-mode new shift direction (Mode-Both only).
    /// @param  keeper       Address that called `rebalance()` and receives
    ///         the keeper reward.
    struct RebalanceCallbackData {
        bool[3] shouldShift;
        int24[3] newLower;
        int24[3] newUpper;
        bool[3] newDir;
        address keeper;
    }

    // -------------------------------------------------------------------- //
    // Immutables (PoolKey decomposed because structs cannot be immutable)  //
    // -------------------------------------------------------------------- //

    /// @notice Lower-sorted currency of the pool (`PoolKey.currency0`).
    Currency public immutable currency0;
    /// @notice Higher-sorted currency of the pool (`PoolKey.currency1`).
    Currency public immutable currency1;
    /// @notice Pool LP fee in hundredths of a bip (`PoolKey.fee`).
    uint24 public immutable fee;
    /// @notice Pool tick spacing (`PoolKey.tickSpacing`).
    int24 public immutable tickSpacing;
    /// @notice Cached `PoolKey.toId()` of the (one) pool this hook serves.
    PoolId public immutable poolId;

    /// @notice Bin width as a multiple of `tickSpacing`.
    uint24 public immutable binWidth;
    /// @notice TWAP averaging window, in seconds.
    uint32 public immutable twapWindow;
    /// @notice Keeper-reward share of rebalance fees, in basis points
    ///         (e.g. 500 = 5%). Bounded `[0, 10_000]` by the constructor.
    uint16 public immutable keeperRewardBps;
    /// @notice Capacity of the TWAP observation ring buffer.
    uint16 public immutable bufferSize;

    /// @notice Minimum allowed `bufferSize`. A buffer of 1 degenerates the
    ///         TWAP into "always last tick", which is a footgun for any
    ///         hook relying on a meaningful average. 8 leaves room for
    ///         genuine smoothing while still being cheap to deploy. Callers
    ///         that intentionally want a tiny buffer must edit the source.
    uint16 internal constant MIN_BUFFER_SIZE = 8;

    /// @notice Maximum allowed `binWidth × tickSpacing` (i.e. `binTicks()`).
    ///         Set to `MAX_TICK / 2` so the rebalance math
    ///         (`rangeUpper + binTicks`, `rangeLower - binTicks`) cannot
    ///         overflow `int24` for any in-range tick. Pool ticks are
    ///         themselves bounded by `MAX_TICK`, so this leaves at least
    ///         one full bin of headroom on either side of any active tick.
    int24 internal constant MAX_BIN_TICKS = 443_636;

    // -------------------------------------------------------------------- //
    // Per-mode state                                                       //
    // -------------------------------------------------------------------- //

    /// @notice Per-mode accounting. Pack first slot: ranges + shares + flags.
    /// @param currentRangeLower      Lower tick of the mode's active v4 position.
    /// @param currentRangeUpper      Upper tick of the mode's active v4 position.
    /// @param totalShares            Sum of all outstanding LP shares for this mode.
    /// @param initialized            False before the first deposit and after
    ///                               last-LP cleanup; controls the lazy-init path.
    /// @param lastShiftDir           Mode-Both only: false = position sits LEFT of
    ///                               price (last move was rightward); true = RIGHT.
    ///                               Ignored for Mode-Right / Mode-Left.
    /// @param feePerShareCumulative0 Accumulator (Q128) of currency0 fees per share.
    /// @param feePerShareCumulative1 Accumulator (Q128) of currency1 fees per share.
    struct ModeState {
        int24 currentRangeLower;
        int24 currentRangeUpper;
        uint128 totalShares;
        bool initialized;
        bool lastShiftDir;
        uint256 feePerShareCumulative0;
        uint256 feePerShareCumulative1;
    }

    /// @dev Per-mode accounting, keyed by mode id.
    mapping(uint8 mode => ModeState) internal _modes;

    // -------------------------------------------------------------------- //
    // Per-NFT state                                                        //
    // -------------------------------------------------------------------- //

    /// @notice Per-LP-NFT accounting.
    /// @param mode         Mode id this position belongs to.
    /// @param shares       Position's per-mode share count.
    /// @param feeSnapshot0 Accumulator value for currency0 at deposit time.
    /// @param feeSnapshot1 Accumulator value for currency1 at deposit time.
    struct PositionInfo {
        uint8 mode;
        uint128 shares;
        uint256 feeSnapshot0;
        uint256 feeSnapshot1;
    }

    /// @dev Per-NFT accounting, keyed by tokenId.
    mapping(uint256 tokenId => PositionInfo) internal _positions;

    /// @notice Monotonically increasing counter for NFT ids.
    uint256 internal _nextTokenId;

    // -------------------------------------------------------------------- //
    // Keeper reward escrow (pull-pattern)                                  //
    // -------------------------------------------------------------------- //

    /// @dev Currency0 owed to a keeper from prior `rebalance()` calls.
    ///      Pull-pattern: rebalance accumulates here, the keeper claims
    ///      via `claimKeeperReward()`. Push-pattern (paying directly
    ///      inside the unlock callback) would let a malicious keeper
    ///      contract — whose `receive`/`fallback` reverts on native ETH
    ///      transfer — DoS the rebalance for everyone. The pull pattern
    ///      isolates that failure mode to the keeper themselves.
    mapping(address keeper => uint256) internal _keeperOwed0;
    /// @dev Currency1 owed to a keeper from prior `rebalance()` calls.
    mapping(address keeper => uint256) internal _keeperOwed1;

    // -------------------------------------------------------------------- //
    // TWAP observation buffer                                              //
    // -------------------------------------------------------------------- //

    /// @notice One TWAP ring-buffer entry.
    /// @param timestamp      Unix seconds at write time.
    /// @param tick           Pool spot tick at write time.
    /// @param tickCumulative Time-weighted sum of ticks since seed,
    ///                       carrying the same semantics as v3 oracle.
    struct Observation {
        uint32 timestamp;
        int24 tick;
        int56 tickCumulative;
    }

    /// @dev Sized at deployment via `bufferSize`. Stored as a dynamic array
    ///      because `bufferSize` is not known at compile time; it is filled
    ///      to `bufferSize` length on first observation.
    Observation[] internal _observations;
    /// @dev Slot of the most-recently-written observation.
    uint16 internal _observationIndex;
    /// @dev Number of valid observations, capped at `bufferSize`.
    uint16 internal _observationCount;

    // -------------------------------------------------------------------- //
    // Constructor                                                          //
    // -------------------------------------------------------------------- //

    /// @notice Deploy a hook for a single Uniswap v4 pool. The hook address
    ///         must encode the permission flags returned by
    ///         `getHookPermissions()` — use `HookMiner` + CREATE2 to find a
    ///         valid salt, and embed the resulting address in `poolKey_`.
    /// @param _poolManager     v4 PoolManager the hook will bind to.
    /// @param poolKey_         The (one) pool this hook serves. Its `hooks`
    ///                         field must equal `address(this)`.
    /// @param _binWidth        Bin width as a multiple of `tickSpacing`. Must
    ///                         be > 0.
    /// @param _twapWindow      TWAP averaging window, in seconds. Must be > 0.
    /// @param _keeperRewardBps Share of rebalance fees paid to the rebalance
    ///                         caller, in basis points. `0 ≤ x ≤ 10_000`.
    /// @param _bufferSize      Capacity of the TWAP observation ring buffer.
    ///                         Must be > 0.
    /// @param _name            ERC-721 collection name.
    /// @param _symbol          ERC-721 collection symbol.
    constructor(
        IPoolManager _poolManager,
        PoolKey memory poolKey_,
        uint24 _binWidth,
        uint32 _twapWindow,
        uint16 _keeperRewardBps,
        uint16 _bufferSize,
        string memory _name,
        string memory _symbol
    ) BaseHook(_poolManager) ERC721(_name, _symbol) {
        // The hook in the PoolKey must point to this very contract — anyone
        // can construct a PoolKey, so we enforce the link explicitly.
        require(address(poolKey_.hooks) == address(this), "PoolKey hook != this");
        require(_binWidth > 0, "binWidth=0");
        require(_twapWindow > 0, "twapWindow=0");
        require(_keeperRewardBps <= 10_000, "keeperRewardBps too large");
        require(_bufferSize >= MIN_BUFFER_SIZE, "bufferSize < MIN_BUFFER_SIZE");
        require(poolKey_.tickSpacing > 0, "tickSpacing=0");
        // binTicks() = binWidth * tickSpacing. Use uint256 to detect any
        // wrap before we cast back to int24. The MAX_BIN_TICKS bound also
        // guarantees rebalance math won't overflow int24 for any in-range
        // tick (the additive expressions stay within ±MAX_TICK).
        require(
            uint256(_binWidth) * uint256(uint24(poolKey_.tickSpacing)) <= uint256(uint24(MAX_BIN_TICKS)),
            "binTicks > MAX_BIN_TICKS"
        );

        currency0 = poolKey_.currency0;
        currency1 = poolKey_.currency1;
        fee = poolKey_.fee;
        tickSpacing = poolKey_.tickSpacing;
        poolId = poolKey_.toId();

        binWidth = _binWidth;
        twapWindow = _twapWindow;
        keeperRewardBps = _keeperRewardBps;
        bufferSize = _bufferSize;
    }

    /// @notice Accept ETH from the PoolManager during native-currency
    ///         `take()` calls. v4's `Currency.transfer` for native currency
    ///         issues a raw `call{value:}` with empty data — without
    ///         `receive`, those transfers would revert and break native-ETH
    ///         pools end-to-end (deposit-poke fee accrual, withdraw, and
    ///         rebalance burn all route currency through the hook). EOAs
    ///         mistakenly sending ETH directly will likewise land here; we
    ///         accept it as a no-op since there is no admin path to recover
    ///         it (matches the hook's intentional no-privileged-roles
    ///         posture — see SECURITY.md).
    receive() external payable {}

    // -------------------------------------------------------------------- //
    // Hook permissions                                                     //
    // -------------------------------------------------------------------- //

    /// @inheritdoc BaseHook
    /// @dev Only `beforeAddLiquidity`, `beforeRemoveLiquidity`, and
    ///      `afterSwap` are enabled. The first two are used to block direct
    ///      external position modification; `afterSwap` writes TWAP
    ///      observations.
    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: false,
            afterInitialize: false,
            beforeAddLiquidity: true,
            afterAddLiquidity: false,
            beforeRemoveLiquidity: true,
            afterRemoveLiquidity: false,
            beforeSwap: false,
            afterSwap: true,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: false,
            afterSwapReturnDelta: false,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    // -------------------------------------------------------------------- //
    // External LP entry points (stubs — filled in steps 4–7)               //
    // -------------------------------------------------------------------- //

    /// @notice Deposit into a directional mode and receive an LP NFT.
    /// @param  mode       Mode id (0=Right, 1=Left, 2=Both).
    /// @param  liquidity  v4 liquidity units to add to the mode's position.
    ///         Caller is responsible for choosing this amount; v4 will pull
    ///         the corresponding currency0/1 amounts from `msg.sender`.
    /// @param  to         Recipient of the LP NFT. May differ from the
    ///         payer (msg.sender), which always funds the deposit.
    /// @return tokenId    Newly-minted LP NFT id.
    /// @dev    Caller must have approved this contract to spend the required
    ///         token amounts (and must have sufficient balance). Native ETH
    ///         is supported by sending `msg.value`.
    function deposit(uint8 mode, uint128 liquidity, address to)
        external
        payable
        nonReentrant
        returns (uint256 tokenId)
    {
        if (mode >= MODE_COUNT) revert InvalidMode();
        if (liquidity == 0) revert ZeroLiquidity();

        // Unlock the manager and execute the deposit inside the callback.
        bytes memory ret = poolManager.unlock(
            abi.encode(
                ACTION_DEPOSIT,
                abi.encode(DepositCallbackData({mode: mode, liquidity: liquidity, payer: msg.sender, recipient: to}))
            )
        );
        DepositResult memory r = abi.decode(ret, (DepositResult));

        // Refund any native-ETH overpayment. Without this, `msg.value`
        // in excess of what the deposit actually consumed would be
        // permanently retained by the hook (the `receive` accepts ETH
        // but there is no admin path to recover it). `nativeSpent` is
        // 0 when neither currency is native, so the branch is a no-op
        // for ERC20-only pools.
        if (msg.value > r.nativeSpent) {
            uint256 refund = msg.value - r.nativeSpent;
            (bool ok,) = msg.sender.call{value: refund}("");
            if (!ok) revert RefundFailed();
        }
        return r.tokenId;
    }

    /// @notice Burn an LP NFT and withdraw the underlying principal + the
    ///         caller's accumulated fees in both currencies.
    /// @param  tokenId  LP NFT id to burn.
    /// @param  to       Recipient of the proceeds. May differ from the
    ///         caller; only the NFT owner (or an approved operator) may
    ///         initiate the withdrawal, but they can direct funds anywhere.
    /// @return amount0  Currency0 sent to `to` (principal + fee share).
    /// @return amount1  Currency1 sent to `to`.
    function withdraw(uint256 tokenId, address to)
        external
        nonReentrant
        returns (uint256 amount0, uint256 amount1)
    {
        // ERC-721 ownership check matches what `_burn` would enforce, but
        // we want a clean revert before opening the unlock callback.
        address owner = _ownerOf(tokenId);
        if (owner == address(0)) revert NotPositionOwner();
        if (msg.sender != owner && !isApprovedForAll(owner, msg.sender) && getApproved(tokenId) != msg.sender) {
            revert NotPositionOwner();
        }

        bytes memory ret = poolManager.unlock(
            abi.encode(ACTION_WITHDRAW, abi.encode(WithdrawCallbackData({tokenId: tokenId, recipient: to})))
        );
        WithdrawResult memory r = abi.decode(ret, (WithdrawResult));
        return (r.amount0, r.amount1);
    }

    /// @notice Permissionless rebalance. Evaluates each initialized mode's
    ///         TWAP trigger; for any that fire, burns the old position,
    ///         pays a fraction of collected fees to the caller as a keeper
    ///         reward, accrues the rest into the per-share accumulator,
    ///         and re-deposits the principal at the new range.
    /// @dev    Reverts `NothingToRebalance` if no initialized mode requires
    ///         a shift — keeper just paid gas for a no-op.
    function rebalance() external nonReentrant {
        // Need at least one observation to compute TWAP.
        if (_observationCount == 0) revert NothingToRebalance();
        int24 twap = this.getTwap();

        RebalanceCallbackData memory rd;
        rd.keeper = msg.sender;

        // `anyShift`     = at least one mode needs a real burn-and-remint
        //                  (drives the unlock).
        // `anyDirFlip`   = at least one mode hit the same-bin shortcut and
        //                  flipped `lastShiftDir` in storage. We must NOT
        //                  revert in this case — that would roll the flip
        //                  back, leaving the mode wedged on the wrong side.
        bool anyShift;
        bool anyDirFlip;
        int24 bt = binTicks();
        for (uint8 m = 0; m < MODE_COUNT; m++) {
            ModeState storage s = _modes[m];
            if (!s.initialized) continue;
            (bool need, int24 nl, int24 nu, bool nd) = ModeRange.nextRebalanceTarget(
                m, twap, s.currentRangeLower, s.currentRangeUpper, bt, s.lastShiftDir
            );
            if (!need) continue;
            // Same-bin no-op (spec §5.5): if the new range happens to equal
            // the current range (can happen for Mode-Both reversal where
            // geometry coincides), skip the physical shift but still flip
            // dir below.
            bool sameRange = (nl == s.currentRangeLower && nu == s.currentRangeUpper);
            rd.shouldShift[m] = !sameRange;
            rd.newLower[m] = nl;
            rd.newUpper[m] = nu;
            rd.newDir[m] = nd;
            if (sameRange) {
                // Just flip dir in-place; no unlock work needed for this mode.
                s.lastShiftDir = nd;
                anyDirFlip = true;
            } else {
                anyShift = true;
            }
        }

        // If neither a real shift nor an in-place dir flip happened, the
        // keeper paid gas for nothing — revert so they don't waste any more.
        if (!anyShift && !anyDirFlip) revert NothingToRebalance();
        // Only unlock when there's actual burn-and-remint work; the
        // dir-flip writes already landed in storage above.
        if (anyShift) {
            poolManager.unlock(abi.encode(ACTION_REBALANCE, abi.encode(rd)));
        }
    }

    /// @notice Withdraw any rebalance rewards owed to `msg.sender`.
    /// @dev    Pull-pattern. Splitting the payout from the rebalance
    ///         itself prevents a malicious keeper contract — whose
    ///         `receive`/`fallback` reverts on incoming native ETH —
    ///         from DoSing every other keeper's rebalance. The cost is
    ///         one extra transaction per claim, which is acceptable
    ///         since keepers are expected to batch many rebalances per
    ///         claim anyway.
    /// @param  to       Recipient of the rewards. May differ from
    ///         `msg.sender`.
    /// @return amount0  Currency0 paid out.
    /// @return amount1  Currency1 paid out.
    function claimKeeperReward(address to)
        external
        nonReentrant
        returns (uint256 amount0, uint256 amount1)
    {
        amount0 = _keeperOwed0[msg.sender];
        amount1 = _keeperOwed1[msg.sender];
        // Zero before transfer (CEI) — even though `to` is caller-
        // controlled and could re-enter, the `nonReentrant` guard plus
        // pre-zeroing makes a re-entry safe.
        if (amount0 > 0) {
            delete _keeperOwed0[msg.sender];
            currency0.transfer(to, amount0);
        }
        if (amount1 > 0) {
            delete _keeperOwed1[msg.sender];
            currency1.transfer(to, amount1);
        }
    }

    /// @notice Read-only view of how much each currency a keeper can
    ///         withdraw via `claimKeeperReward`.
    /// @param  keeper  Address whose escrow to inspect.
    /// @return owed0   Currency0 currently owed.
    /// @return owed1   Currency1 currently owed.
    function keeperRewardOwed(address keeper) external view returns (uint256 owed0, uint256 owed1) {
        return (_keeperOwed0[keeper], _keeperOwed1[keeper]);
    }

    // -------------------------------------------------------------------- //
    // PoolManager callbacks                                                //
    // -------------------------------------------------------------------- //

    /// @inheritdoc BaseHook
    /// @dev Block all external add-liquidity calls. The hook itself never
    ///      reaches this callback for its own modifies because v4's `Hooks`
    ///      library short-circuits self-calls (see `Hooks.beforeModifyLiquidity`
    ///      which bypasses `noSelfCall`). External LPs must use `deposit`.
    function _beforeAddLiquidity(
        address, /* sender */
        PoolKey calldata key,
        ModifyLiquidityParams calldata, /* params */
        bytes calldata /* hookData */
    ) internal view override returns (bytes4) {
        _requireOurPool(key);
        revert DirectLiquidityModificationDisabled();
    }

    /// @inheritdoc BaseHook
    /// @dev Block all external remove-liquidity calls. Same rationale as
    ///      `_beforeAddLiquidity`. LPs must use `withdraw`.
    function _beforeRemoveLiquidity(
        address, /* sender */
        PoolKey calldata key,
        ModifyLiquidityParams calldata, /* params */
        bytes calldata /* hookData */
    ) internal view override returns (bytes4) {
        _requireOurPool(key);
        revert DirectLiquidityModificationDisabled();
    }

    /// @inheritdoc BaseHook
    /// @dev Writes one TWAP observation per swap. The cumulative tick is
    ///      advanced from the previous observation's `tick × elapsed`.
    function _afterSwap(
        address, /* sender */
        PoolKey calldata key,
        SwapParams calldata, /* params */
        BalanceDelta, /* delta */
        bytes calldata /* hookData */
    ) internal override returns (bytes4, int128) {
        _requireOurPool(key);
        _writeObservation();
        return (BaseHook.afterSwap.selector, 0);
    }

    // -------------------------------------------------------------------- //
    // Unlock callback                                                      //
    // -------------------------------------------------------------------- //

    /// @inheritdoc IUnlockCallback
    /// @dev Only callable by the configured `poolManager`. The hook itself
    ///      is the only initiator of `unlock` (via `deposit`/`withdraw`/
    ///      `rebalance`), so `payer/recipient` come from inside this
    ///      contract and are trusted.
    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        if (msg.sender != address(poolManager)) revert NotPoolManagerUnlock();
        (uint8 action, bytes memory payload) = abi.decode(data, (uint8, bytes));
        if (action == ACTION_DEPOSIT) {
            DepositCallbackData memory d = abi.decode(payload, (DepositCallbackData));
            return abi.encode(_doDeposit(d));
        }
        if (action == ACTION_WITHDRAW) {
            WithdrawCallbackData memory w = abi.decode(payload, (WithdrawCallbackData));
            return abi.encode(_doWithdraw(w));
        }
        if (action == ACTION_REBALANCE) {
            RebalanceCallbackData memory rd = abi.decode(payload, (RebalanceCallbackData));
            _doRebalance(rd);
            return bytes("");
        }
        revert UnknownAction();
    }

    // -------------------------------------------------------------------- //
    // Internal: deposit                                                    //
    // -------------------------------------------------------------------- //

    /// @dev Inner half of `deposit`. Runs inside `poolManager.unlock`. Lazy-
    ///      initializes the mode if needed (spec §5.1) or pro-rata mints
    ///      shares against existing liquidity (spec §5.2 — landing in the
    ///      next build step). For now, only the first-deposit path is
    ///      implemented; subsequent deposits revert.
    function _doDeposit(DepositCallbackData memory d) internal returns (DepositResult memory r) {
        ModeState storage state = _modes[d.mode];

        int24 rangeLower;
        int24 rangeUpper;
        uint128 sharesIssued;
        bool dir;

        if (!state.initialized) {
            // -------------- First deposit (lazy init) ---------------
            // Reference tick = pool's spot tick (per spec §5.1; TWAP may
            // not yet be available on a fresh hook).
            (, int24 spotTick,,) = poolManager.getSlot0(poolId);
            dir = ModeRange.initialBothShiftDir();
            (rangeLower, rangeUpper) = ModeRange.rangeForMode(d.mode, spotTick, binTicks(), dir);

            sharesIssued = d.liquidity; // 1:1 init per spec §5.1.4
        } else {
            // -------------- Subsequent deposit (spec §5.2) ----------
            // Reuse the mode's existing range. We accrue any pending fees
            // BEFORE issuing new shares so the new LP doesn't claim past
            // fees (the JIT-attack defense is also reinforced by the
            // snapshot we record below at the post-accrual cumulative).
            rangeLower = state.currentRangeLower;
            rangeUpper = state.currentRangeUpper;
            dir = state.lastShiftDir;

            // Read the mode's current liquidity from v4 to compute pro-rata.
            uint128 modeLiq = _modeLiquidity(d.mode, rangeLower, rangeUpper);
            // First, poke the position with a zero modify to collect any
            // pending fees so we can accrue them before sharing. The poke's
            // callerDelta equals feesAccrued (no principal moved); we take()
            // it to the hook so the open delta is closed before the real
            // add and the fees become ERC20 balance owed to existing LPs.
            (BalanceDelta pokeDelta,) = poolManager.modifyLiquidity(
                _poolKey(),
                ModifyLiquidityParams({
                    tickLower: rangeLower,
                    tickUpper: rangeUpper,
                    liquidityDelta: 0,
                    salt: bytes32(uint256(d.mode))
                }),
                bytes("")
            );
            if (pokeDelta.amount0() > 0) {
                poolManager.take(currency0, address(this), uint256(uint128(pokeDelta.amount0())));
            }
            if (pokeDelta.amount1() > 0) {
                poolManager.take(currency1, address(this), uint256(uint128(pokeDelta.amount1())));
            }
            _accrueAndCustodyFees(state, pokeDelta);

            sharesIssued = ShareMath.sharesForDeposit(d.liquidity, state.totalShares, modeLiq);
        }

        // Add liquidity to the mode's v4 position. `salt = mode` keeps the
        // three modes' positions distinct even when ranges overlap.
        PoolKey memory pk = _poolKey();
        (BalanceDelta callerDelta,) = poolManager.modifyLiquidity(
            pk,
            ModifyLiquidityParams({
                tickLower: rangeLower,
                tickUpper: rangeUpper,
                liquidityDelta: int256(uint256(d.liquidity)),
                salt: bytes32(uint256(d.mode))
            }),
            bytes("")
        );

        // For an add, both delta legs must be ≤ 0 (we owe the pool). A
        // positive delta would mean the pool is paying the hook — defensive
        // check for unexpected v4 behavior.
        int128 amt0 = callerDelta.amount0();
        int128 amt1 = callerDelta.amount1();
        if (amt0 > 0 || amt1 > 0) revert UnexpectedPositiveDelta();

        if (amt0 < 0) {
            uint256 owed0 = uint256(uint128(-amt0));
            _settleFromPayer(currency0, d.payer, owed0);
            // Native ETH (if either currency is native) is always
            // currency0 by v4's sort order — record the spend so
            // `deposit` can refund any `msg.value` overpayment.
            if (currency0.isAddressZero()) r.nativeSpent = owed0;
        }
        if (amt1 < 0) _settleFromPayer(currency1, d.payer, uint256(uint128(-amt1)));

        // Persist mode state. On first init we set everything; on follow-on
        // we only bump `totalShares` (range/dir already match; accumulators
        // were updated in the poke branch above).
        if (!state.initialized) {
            state.currentRangeLower = rangeLower;
            state.currentRangeUpper = rangeUpper;
            state.totalShares = sharesIssued;
            state.initialized = true;
            state.lastShiftDir = dir;
            // feePerShareCumulative0/1 already zero from default storage.
        } else {
            state.totalShares += sharesIssued;
        }

        // Mint the LP NFT. Spec §7.9: `_mint` (no callback) avoids the
        // ERC-721 `onERC721Received` reentry surface; we're inside an
        // unlock callback already so reentrancy via `_safeMint` would be
        // worst-case dangerous.
        unchecked {
            r.tokenId = ++_nextTokenId;
        }
        _mint(d.recipient, r.tokenId);
        _positions[r.tokenId] = PositionInfo({
            mode: d.mode,
            shares: sharesIssued,
            feeSnapshot0: state.feePerShareCumulative0,
            feeSnapshot1: state.feePerShareCumulative1
        });

        r.rangeLower = rangeLower;
        r.rangeUpper = rangeUpper;
        r.sharesIssued = sharesIssued;
    }

    /// @dev Inner half of `withdraw`. Burns the LP NFT, removes the pro-rata
    ///      liquidity slice from v4, accrues collected fees into the mode's
    ///      accumulator, and pays the LP `principal + their_fee_share`. Any
    ///      fees attributable to remaining LPs are taken to the hook and
    ///      held as ERC20 balance until those LPs themselves withdraw —
    ///      that's the invariant that makes the accumulator pattern
    ///      self-funding without re-depositing fees back into the position
    ///      (which would inadvertently dilute fees across all LPs).
    function _doWithdraw(WithdrawCallbackData memory w) internal returns (WithdrawResult memory r) {
        PositionInfo memory pos = _positions[w.tokenId];
        ModeState storage state = _modes[pos.mode];
        if (!state.initialized) revert NotPositionOwner(); // mode reset; NFT stale

        BalanceDelta callerDelta;
        BalanceDelta feesAccrued;
        uint128 totalSharesBefore = state.totalShares;
        {
            uint128 modeLiq = _modeLiquidity(pos.mode, state.currentRangeLower, state.currentRangeUpper);
            uint128 liquidityOut = ShareMath.liquidityForWithdraw(pos.shares, totalSharesBefore, modeLiq);
            (callerDelta, feesAccrued) = poolManager.modifyLiquidity(
                _poolKey(),
                ModifyLiquidityParams({
                    tickLower: state.currentRangeLower,
                    tickUpper: state.currentRangeUpper,
                    liquidityDelta: -int256(uint256(liquidityOut)),
                    salt: bytes32(uint256(pos.mode))
                }),
                bytes("")
            );
        }

        // Accrue fees using `totalSharesBefore` — those fees were earned by
        // all outstanding shares, including the withdrawer's.
        _accrueAndCustodyFees(state, feesAccrued);

        // Compute LP payout (principal + their share of post-accrual fees).
        {
            int128 prin0 = callerDelta.amount0() - feesAccrued.amount0();
            int128 prin1 = callerDelta.amount1() - feesAccrued.amount1();
            if (prin0 < 0 || prin1 < 0) revert UnexpectedNegativePrincipal();
            r.amount0 = uint256(uint128(prin0))
                + ShareMath.pendingFees(pos.shares, state.feePerShareCumulative0, pos.feeSnapshot0);
            r.amount1 = uint256(uint128(prin1))
                + ShareMath.pendingFees(pos.shares, state.feePerShareCumulative1, pos.feeSnapshot1);
        }

        // Drain the manager: principal + all collected fees come to the
        // hook. Withdrawer's slice goes straight to the recipient; the
        // residual fees stay as ERC20 balance owed to remaining LPs.
        if (callerDelta.amount0() > 0) {
            poolManager.take(currency0, address(this), uint256(uint128(callerDelta.amount0())));
        }
        if (callerDelta.amount1() > 0) {
            poolManager.take(currency1, address(this), uint256(uint128(callerDelta.amount1())));
        }
        if (r.amount0 > 0) currency0.transfer(w.recipient, r.amount0);
        if (r.amount1 > 0) currency1.transfer(w.recipient, r.amount1);

        // Burn shares, NFT, position info; reset mode if last LP out.
        unchecked {
            state.totalShares = totalSharesBefore - pos.shares;
        }
        _burn(w.tokenId);
        delete _positions[w.tokenId];
        if (state.totalShares == 0) {
            delete _modes[pos.mode]; // spec §5.3.9 — re-init on next deposit
        }
    }

    /// @dev Read the mode's current v4 position liquidity. The position is
    ///      keyed by (this hook, range, salt=mode).
    function _modeLiquidity(uint8 mode, int24 lower, int24 upper) internal view returns (uint128) {
        bytes32 positionKey = Position.calculatePositionKey(address(this), lower, upper, bytes32(uint256(mode)));
        return poolManager.getPositionLiquidity(poolId, positionKey);
    }

    // -------------------------------------------------------------------- //
    // Internal: rebalance                                                  //
    // -------------------------------------------------------------------- //

    /// @dev Inner half of `rebalance`. Iterates the per-mode shift list,
    ///      burning + reminting one v4 position per shifting mode, with
    ///      fees split between LP accumulator and keeper. Modes whose
    ///      `shouldShift[i]` is false (including modes that flipped dir
    ///      in-place via the same-bin shortcut) are untouched.
    function _doRebalance(RebalanceCallbackData memory rd) internal {
        // Per-currency keeper reward accumulator. Folded into the
        // pull-pattern escrow at the end of the loop so a multi-mode
        // rebalance only writes one storage slot per currency.
        uint256 keeperReward0;
        uint256 keeperReward1;

        for (uint8 m = 0; m < MODE_COUNT; m++) {
            if (!rd.shouldShift[m]) continue;
            (uint256 kr0, uint256 kr1) = _shiftMode(m, rd.newLower[m], rd.newUpper[m], rd.newDir[m]);
            keeperReward0 += kr0;
            keeperReward1 += kr1;
        }

        // Pull-pattern: credit the keeper's escrow rather than paying
        // out inline. Keepers withdraw via `claimKeeperReward()`. See the
        // `_keeperOwed{0,1}` doc for the rationale.
        if (keeperReward0 > 0) _keeperOwed0[rd.keeper] += keeperReward0;
        if (keeperReward1 > 0) _keeperOwed1[rd.keeper] += keeperReward1;
    }

    /// @dev Burns mode `m`'s old position, accrues collected fees (minus
    ///      the keeper cut) into the per-share accumulator, computes the
    ///      maximum liquidity we can re-mint at the new range using the
    ///      principal we just got back, and mints there.
    /// @return keeperReward0 Keeper's currency0 cut from this mode's fees.
    /// @return keeperReward1 Keeper's currency1 cut from this mode's fees.
    function _shiftMode(uint8 m, int24 newLower, int24 newUpper, bool newDir)
        internal
        returns (uint256 keeperReward0, uint256 keeperReward1)
    {
        ModeState storage s = _modes[m];
        (BalanceDelta callerDelta, BalanceDelta feesAccrued) = _burnOldPosition(m, s);
        (keeperReward0, keeperReward1) = _splitFeesForKeeper(s, feesAccrued);
        _remintAtNewRange(m, newLower, newUpper, callerDelta, feesAccrued);
        s.currentRangeLower = newLower;
        s.currentRangeUpper = newUpper;
        s.lastShiftDir = newDir;
    }

    /// @dev Burn the mode's existing v4 position and take the proceeds to
    ///      the hook (for splitting between fees + keeper + new mint).
    function _burnOldPosition(uint8 m, ModeState storage s)
        internal
        returns (BalanceDelta callerDelta, BalanceDelta feesAccrued)
    {
        uint128 oldLiq = _modeLiquidity(m, s.currentRangeLower, s.currentRangeUpper);
        if (oldLiq == 0) return (callerDelta, feesAccrued);
        (callerDelta, feesAccrued) = poolManager.modifyLiquidity(
            _poolKey(),
            ModifyLiquidityParams({
                tickLower: s.currentRangeLower,
                tickUpper: s.currentRangeUpper,
                liquidityDelta: -int256(uint256(oldLiq)),
                salt: bytes32(uint256(m))
            }),
            bytes("")
        );
        if (callerDelta.amount0() > 0) {
            poolManager.take(currency0, address(this), uint256(uint128(callerDelta.amount0())));
        }
        if (callerDelta.amount1() > 0) {
            poolManager.take(currency1, address(this), uint256(uint128(callerDelta.amount1())));
        }
    }

    /// @dev Allocate `feesAccrued` between keeper and LPs. Keeper's cut is
    ///      returned; LP cut is folded into the per-share accumulator.
    function _splitFeesForKeeper(ModeState storage s, BalanceDelta feesAccrued)
        internal
        returns (uint256 keeperReward0, uint256 keeperReward1)
    {
        if (feesAccrued.amount0() > 0) {
            uint256 fee0 = uint256(uint128(feesAccrued.amount0()));
            keeperReward0 = fee0 * keeperRewardBps / 10_000;
            s.feePerShareCumulative0 =
                ShareMath.accrueFeePerShare(s.feePerShareCumulative0, fee0 - keeperReward0, s.totalShares);
        }
        if (feesAccrued.amount1() > 0) {
            uint256 fee1 = uint256(uint128(feesAccrued.amount1()));
            keeperReward1 = fee1 * keeperRewardBps / 10_000;
            s.feePerShareCumulative1 =
                ShareMath.accrueFeePerShare(s.feePerShareCumulative1, fee1 - keeperReward1, s.totalShares);
        }
    }

    /// @dev Mint a new mode position using single-sided principal taken
    ///      from the just-burned old position. Settles the negative delta
    ///      directly from the hook's ERC20 balance.
    function _remintAtNewRange(
        uint8 m,
        int24 newLower,
        int24 newUpper,
        BalanceDelta callerDelta,
        BalanceDelta feesAccrued
    ) internal {
        int128 prin0 = callerDelta.amount0() - feesAccrued.amount0();
        int128 prin1 = callerDelta.amount1() - feesAccrued.amount1();
        uint128 newLiq = _liquidityForSingleSidedRange(newLower, newUpper, prin0, prin1);
        if (newLiq == 0) return;

        (BalanceDelta newCallerDelta,) = poolManager.modifyLiquidity(
            _poolKey(),
            ModifyLiquidityParams({
                tickLower: newLower,
                tickUpper: newUpper,
                liquidityDelta: int256(uint256(newLiq)),
                salt: bytes32(uint256(m))
            }),
            bytes("")
        );
        if (newCallerDelta.amount0() < 0) {
            _settleFromHook(currency0, uint256(uint128(-newCallerDelta.amount0())));
        }
        if (newCallerDelta.amount1() < 0) {
            _settleFromHook(currency1, uint256(uint128(-newCallerDelta.amount1())));
        }
    }

    /// @dev Compute max liquidity at `[lower, upper)` given single-sided
    ///      principal in either currency. The mode invariant guarantees
    ///      principal arrives in exactly one currency: positions one bin
    ///      below active hold currency1; positions one bin above hold
    ///      currency0. Mode-Both swap-through preserves this — the burned
    ///      position is fully on the side it should be on.
    function _liquidityForSingleSidedRange(int24 lower, int24 upper, int128 prin0, int128 prin1)
        internal
        pure
        returns (uint128)
    {
        uint160 sqrtA = TickMath.getSqrtPriceAtTick(lower);
        uint160 sqrtB = TickMath.getSqrtPriceAtTick(upper);
        if (prin1 > 0 && prin0 == 0) {
            // Currency1-only: position below active.
            return LiquidityAmounts.getLiquidityForAmount1(sqrtA, sqrtB, uint256(uint128(prin1)));
        }
        if (prin0 > 0 && prin1 == 0) {
            // Currency0-only: position above active.
            return LiquidityAmounts.getLiquidityForAmount0(sqrtA, sqrtB, uint256(uint128(prin0)));
        }
        if (prin0 == 0 && prin1 == 0) {
            // Empty principal (edge case: mode held 0 liquidity). Mint nothing.
            return 0;
        }
        // Both legs positive — would mean the burned position straddled
        // active. Our invariant says this shouldn't happen for any mode.
        // Fall back to `getLiquidityForAmounts` with the burn's price as
        // a best-effort, but flag the irregularity.
        revert UnexpectedPositiveDelta();
    }

    /// @dev Settle a negative delta on the manager using the hook's own
    ///      ERC20 balance (paired with `modifyLiquidity` adds during a
    ///      rebalance, where principal is already in the hook from the
    ///      preceding burn).
    function _settleFromHook(Currency currency, uint256 amount) internal {
        if (currency.isAddressZero()) {
            poolManager.settle{value: amount}();
        } else {
            poolManager.sync(currency);
            (bool ok, bytes memory ret) = Currency.unwrap(currency).call(
                abi.encodeWithSelector(IERC20Minimal.transfer.selector, address(poolManager), amount)
            );
            require(ok && (ret.length == 0 || abi.decode(ret, (bool))), "transfer failed");
            poolManager.settle();
        }
    }

    /// @dev Accrue per-share fee growth for both currencies. Caller is
    ///      responsible for the `totalShares` denominator being correct
    ///      (i.e. the pre-burn share count for withdrawals, current count
    ///      for the deposit-poke path).
    function _accrueAndCustodyFees(ModeState storage state, BalanceDelta feesAccrued) internal {
        uint128 ts = state.totalShares;
        int128 f0 = feesAccrued.amount0();
        int128 f1 = feesAccrued.amount1();
        if (f0 > 0) state.feePerShareCumulative0 = ShareMath.accrueFeePerShare(state.feePerShareCumulative0, uint256(uint128(f0)), ts);
        if (f1 > 0) state.feePerShareCumulative1 = ShareMath.accrueFeePerShare(state.feePerShareCumulative1, uint256(uint128(f1)), ts);
        // The corresponding currency credits get drained out by
        // `_doDeposit`/`_doWithdraw` paths via subsequent modifies + take()
        // calls — never leave open positive deltas across an unlock.
    }

    /// @dev Pull `amount` of `currency` from `payer` to the PoolManager and
    ///      settle the open delta. Supports both ERC20 (`transferFrom`) and
    ///      native ETH (msg.value forwarded via `settle{value: amount}()`).
    function _settleFromPayer(Currency currency, address payer, uint256 amount) internal {
        if (currency.isAddressZero()) {
            // Native: caller forwarded ETH via `deposit{value: ...}`. The
            // hook holds it in this transaction — forward to the manager.
            poolManager.settle{value: amount}();
        } else {
            // ERC20: sync, transfer payer→manager, settle.
            poolManager.sync(currency);
            // safe-transferFrom directly into the manager. Reverts on
            // insufficient allowance/balance, no need to check return data
            // for compliant tokens; non-compliant tokens are not supported.
            address token = Currency.unwrap(currency);
            // Use call to handle non-standard return values uniformly.
            (bool ok, bytes memory ret) = token.call(
                abi.encodeWithSelector(IERC20Minimal.transferFrom.selector, payer, address(poolManager), amount)
            );
            require(ok && (ret.length == 0 || abi.decode(ret, (bool))), "transferFrom failed");
            poolManager.settle();
        }
    }

    /// @dev Reconstruct the immutable PoolKey for use in v4 calls.
    function _poolKey() internal view returns (PoolKey memory) {
        return PoolKey({
            currency0: currency0,
            currency1: currency1,
            fee: fee,
            tickSpacing: tickSpacing,
            hooks: this
        });
    }

    // -------------------------------------------------------------------- //
    // Read helpers                                                         //
    // -------------------------------------------------------------------- //

    /// @notice Returns this hook's `PoolKey`, reconstructed from immutables.
    function poolKey() external view returns (PoolKey memory) {
        return _poolKey();
    }

    /// @notice Read-only view of an LP position's accounting state.
    function positionInfo(uint256 tokenId) external view returns (PositionInfo memory) {
        return _positions[tokenId];
    }

    /// @notice Read-only view of a mode's accounting state.
    function modeState(uint8 mode) external view returns (ModeState memory) {
        return _modes[mode];
    }

    /// @notice Bin width in ticks: `binWidth × tickSpacing`.
    function binTicks() public view returns (int24) {
        return int24(uint24(binWidth)) * tickSpacing;
    }

    /// @notice Where would `mode` place its position if it were initialized
    ///         (or rebalanced) at `referenceTick` right now? Pure geometry.
    /// @dev    For Mode Both, `bothShiftDir` reflects the prevailing
    ///         direction marker (false = position to the left of price).
    function rangeForMode(uint8 mode, int24 referenceTick, bool bothShiftDir)
        external
        view
        returns (int24 lower, int24 upper)
    {
        return ModeRange.rangeForMode(mode, referenceTick, binTicks(), bothShiftDir);
    }

    // -------------------------------------------------------------------- //
    // TWAP                                                                 //
    // -------------------------------------------------------------------- //

    /// @notice Total observations the buffer currently holds (capped at
    ///         `bufferSize` once the ring has wrapped).
    function observationCount() external view returns (uint16) {
        return _observationCount;
    }

    /// @notice Index of the most-recently-written observation (the head of
    ///         the ring buffer). Undefined when `observationCount == 0`.
    function observationIndex() external view returns (uint16) {
        return _observationIndex;
    }

    /// @notice Returns observation `i`. `i` is a slot index, not a recency
    ///         rank — slot `_observationIndex` is the most recent.
    function getObservation(uint16 i) external view returns (Observation memory) {
        return _observations[i];
    }

    /// @notice TWAP tick over `twapWindow` seconds, ending at `block.timestamp`.
    /// @dev Walks the ring buffer to find an observation older than the
    ///      window start; interpolates if needed. Falls back to the most
    ///      recent observation's tick if the buffer doesn't yet span the
    ///      window (warmup) — this matches v3-oracle low-volume behavior.
    /// @return tick The arithmetic-mean tick over the window.
    function getTwap() external view returns (int24 tick) {
        uint16 count = _observationCount;
        if (count == 0) revert NoObservations();

        uint16 head = _observationIndex;
        Observation memory newest = _observations[head];

        // Synthesize a "now" cumulative by extending newest forward to the
        // current timestamp at the newest observation's tick. This makes
        // TWAP self-consistent if no swap has happened recently.
        uint32 nowTs = uint32(block.timestamp);
        int56 nowCumulative = newest.tickCumulative
            + int56(int256(uint256(nowTs - newest.timestamp))) * int56(newest.tick);

        // Window start. If the window pre-dates the buffer, fall back to the
        // most recent tick (warmup / low-volume degradation).
        uint32 target;
        unchecked {
            target = nowTs - twapWindow;
        }
        if (nowTs <= twapWindow) {
            // Window start would be < 0; no meaningful TWAP yet.
            return newest.tick;
        }

        // If even the oldest observation is newer than `target`, we don't
        // have enough history — fall back to spot tick from the most recent.
        uint16 oldestIdx = (count < bufferSize) ? 0 : ((head + 1) % bufferSize);
        Observation memory oldest = _observations[oldestIdx];
        if (oldest.timestamp >= target) {
            return newest.tick;
        }

        // Walk newest → oldest and find the first observation at or before
        // `target`. We then interpolate between it and its successor to get
        // a synthesized cumulative at `target`.
        Observation memory atOrBefore = newest;
        Observation memory after_ = newest;
        bool hasAfter = false; // tracks whether `after_` is a real successor

        // Iterate at most `count` steps. Start from newest and step backward.
        uint16 idx = head;
        for (uint16 i = 0; i < count; i++) {
            Observation memory o = _observations[idx];
            if (o.timestamp <= target) {
                atOrBefore = o;
                break;
            }
            after_ = o;
            hasAfter = true;
            // Step back one slot in the ring.
            idx = (idx == 0) ? (bufferSize - 1) : (idx - 1);
        }

        int56 targetCumulative;
        if (!hasAfter) {
            // `target` is at-or-after the newest observation. Extrapolate
            // forward from `atOrBefore == newest` at its tick.
            uint32 dt = target - atOrBefore.timestamp;
            targetCumulative = atOrBefore.tickCumulative + int56(int256(uint256(dt))) * int56(atOrBefore.tick);
        } else if (atOrBefore.timestamp == after_.timestamp) {
            // Two observations in the same second — degenerate; just take
            // the cumulative at that point.
            targetCumulative = atOrBefore.tickCumulative;
        } else {
            // Linear interpolation between `atOrBefore` and `after_`.
            uint32 span = after_.timestamp - atOrBefore.timestamp;
            uint32 dt = target - atOrBefore.timestamp;
            int56 deltaCumulative = after_.tickCumulative - atOrBefore.tickCumulative;
            targetCumulative = atOrBefore.tickCumulative
                + int56(int256(uint256(dt))) * deltaCumulative / int56(int256(uint256(span)));
        }

        // Average tick over the window = Δcumulative / window.
        int56 windowCumulative = nowCumulative - targetCumulative;
        tick = int24(windowCumulative / int56(int256(uint256(twapWindow))));
    }

    // -------------------------------------------------------------------- //
    // Internal                                                             //
    // -------------------------------------------------------------------- //

    /// @dev Validates that the incoming PoolKey is the one this hook was
    ///      deployed for. Compared by id (cheaper than struct comparison).
    function _requireOurPool(PoolKey calldata key) internal view {
        if (PoolId.unwrap(key.toId()) != PoolId.unwrap(poolId)) revert WrongPool();
    }

    /// @dev Append one observation to the ring buffer at the post-swap tick.
    ///      Two same-second swaps overwrite each other (the second swap's
    ///      tick replaces the first; cumulative is consistent because the
    ///      first contributed `0 × tick` to it).
    function _writeObservation() internal {
        (, int24 currentTick,,) = poolManager.getSlot0(poolId);
        uint32 nowTs = uint32(block.timestamp);

        // Empty buffer — seed slot 0.
        if (_observationCount == 0) {
            _observations.push(Observation({timestamp: nowTs, tick: currentTick, tickCumulative: 0}));
            _observationIndex = 0;
            _observationCount = 1;
            return;
        }

        Observation memory prev = _observations[_observationIndex];

        // Same-second swap: overwrite the head; tickCumulative unchanged
        // because no time elapsed since the last write.
        if (nowTs == prev.timestamp) {
            _observations[_observationIndex] =
                Observation({timestamp: nowTs, tick: currentTick, tickCumulative: prev.tickCumulative});
            return;
        }

        // Advance: cumulative grows by prev.tick × elapsed.
        int56 cumulative =
            prev.tickCumulative + int56(int256(uint256(nowTs - prev.timestamp))) * int56(prev.tick);

        uint16 newIdx;
        if (_observationCount < bufferSize) {
            // Still filling the buffer — push a new slot.
            newIdx = uint16(_observations.length);
            _observations.push(Observation({timestamp: nowTs, tick: currentTick, tickCumulative: cumulative}));
            _observationCount = uint16(_observations.length);
        } else {
            // Full ring — wrap.
            newIdx = (_observationIndex + 1) % bufferSize;
            _observations[newIdx] = Observation({timestamp: nowTs, tick: currentTick, tickCumulative: cumulative});
        }
        _observationIndex = newIdx;
    }
}
