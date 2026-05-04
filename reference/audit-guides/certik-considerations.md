# Uniswap V4 Hooks: Security Considerations (CertiK)

> **Source**: https://www.certik.com/resources/blog/uniswap-v4-hooks-security-considerations
> **Author**: CertiK

CertiK's framing of the v4 hook security model. Distinguishes between attack surfaces at different interfaces.

## Two security interfaces

### 1. Hook ↔ PoolManager interface
Uniswap V4 has **robust security mechanisms** to protect against a malicious hook tampering with PoolManager logic. The PoolManager defends itself.

But: hook integration can still be **incorrect** — meaning the hook fails to follow PoolManager's expected interface and breaks itself or the pool. This isn't malice, it's bugs.

The V4-core PoolManager enforces several requirements on hook integration. Hook developers must understand these requirements to ensure hooks function as intended.

### 2. Hook ↔ User interface
This is where most risk lives. The hook-user interface contains custom logic and has a **broader attack surface** than the protocol layer. Depending on design, the hook can:
- Act as a **custodian of user funds** → vulnerabilities cause direct loss
- Contain **execution logic only** → never takes possession of funds

When a hook acts as custodian, every vulnerability in the hook contract risks direct fund loss and requires close scrutiny.

## Privileged role risk

Like any smart contract, hooks may legitimately have privileged roles (admin, owner, oracle updater). But if a privileged address is compromised:
- An upgradeable hook holding user funds can have a malicious withdrawal function injected via contract upgrade
- A hook with an owner-controlled fee parameter can be set to extract value from every swap
- An owner-controlled allowlist can grant access to malicious pools

**Mitigation**: minimize privileges; use multisigs or DAOs for critical roles; timelock parameter changes; consider making the hook fully immutable.

## Permission encoding mechanism

The permission system inspects the **least significant bits** of the deployed hook address. Once deployed, **permissions cannot be changed** — they're baked into the address.

Implications:
- A salt-mining bug at deployment time produces a hook with wrong permissions → pool initialization reverts, or worse, the hook silently has more permissions than intended
- You cannot fix this without redeploying to a new address
- All integrations referencing the old address must update

## Return values affect swap logic

Two hook calls have return values that directly impact swap outcomes:
- `beforeSwap` returns an `lpFeeOverride` that can change the fee charged for the swap (only effective if the pool was initialized with the dynamic-fee flag)
- `afterSwap` returns a `hookDelta` that changes the distribution of currency deltas between `msg.sender` and the hook address

If the `beforeSwap` and `afterSwap` flags are `false`, the hook is never called and these effects are no-ops.

If the flags are `true`, the hook is **trusted with swap economics**. Ensure the math is correct, the sign convention is documented, and the values are bounded.

## Inheritance from BaseHook

The article emphasizes inheriting from `BaseHook` to avoid permission mismatches and ensure standard handling of:
- Access control (the IHooks functions enforce `onlyPoolManager`)
- Selector returns (BaseHook returns the right selector by default)
- Override patterns (the underscore-prefixed internal functions are the right hook points)

Skipping `BaseHook` and implementing `IHooks` directly is allowed but error-prone.

## Other points of caution

| Concern | Action |
|---|---|
| Validate return values | Wrong return type/size → transaction reverts with `InvalidHookResponse` |
| Restrict access | Prevent unauthorized direct calls; auxiliary functions need explicit checks |
| Audit all upgradeable contracts | Centralization risk in proxies, beacons, upgradeable patterns |
| Validate input parameters | Especially `PoolKey` — attackers will pass malicious keys |
| Be cautious modifying `hookDelta` | Wrong signs or magnitudes can let users (or the hook) steal value |
