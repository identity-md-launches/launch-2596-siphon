# SIPHON (SIPH)

A fixed-supply ERC-20 token for Robinhood Chain (chain id 4663), built as an IdentityMD
custom-token launch.

| Field | Value |
| --- | --- |
| Solidity contract | `SiphonToken` (`src/SiphonToken.sol`) |
| `name()` | `SIPHON` |
| `symbol()` | `SIPH` |
| `decimals()` | `18` |
| `totalSupply()` | `1_000_000_000 * 10**18` = `1000000000000000000000000000` minor units |
| Constructor arguments | none |
| Owner / admin | none |
| Mint after deploy | impossible (no mint function; `_mint` only runs in the constructor) |
| Burn | none exposed |
| Transfer fee / tax / restriction | none |

## Behaviour

The constructor mints the whole supply once to `msg.sender` and emits the standard ERC-20
`Transfer(address(0), msg.sender, supply)` plus a `SupplyMinted(recipient, amount)` event. After
that the contract is a plain OpenZeppelin v5 ERC-20: `transfer`, `approve`, `transferFrom`,
`allowance`, `balanceOf`, `totalSupply`, `name`, `symbol`, `decimals`.

There is deliberately nothing else:

- no `Ownable`, no owner, no role;
- no `mint`, `burn`, `burnFrom`, `pause`, blacklist, freeze, seize or upgrade path;
- no `receive`/`fallback`, so plain ETH sent to the token reverts;
- no DELEGATECALL, CALLCODE or SELFDESTRUCT in the runtime (a test scans the bytecode);
- no external calls from the constructor, so it deploys on an empty chain;
- no library with external functions, so the bytecode has no link placeholders.

## Assumptions

- The brief asks only for name, symbol and a fixed one-billion supply minted to the deployer.
  No tax, burn, vesting, governance or exemption logic was requested, so none is implemented.
  Because transfers are unconditional, the launch flows (factory to distributor, distributor to
  claimant, factory to pool, trader to and from the pool) move exactly what they say.
- "Deployer" is whichever address runs the constructor. At launch that is the IdentityMD
  `ProjectFactory`, which receives the entire supply and distributes it per the launch policy.
  The token has no notion of a launch factory, pool manager or distributor; it needs none.
- Decimals are 18 as specified.

## Deployment parameters

The token takes **no constructor arguments**. The launch manifest step (not this repository)
records:

- `token.contract`: `SiphonToken`
- `token.name`: `SIPHON`
- `token.symbol`: `SIPH`
- `token.decimals`: `18`
- `token.totalSupply`: `1000000000000000000000000000`
- `token.constructorArgs`: `[]`
- no application contracts (`contracts: []`).

Launch-decided values that are fixed by the policy and not configurable here: native ETH pair,
pool fee 12500 (1.25%), tick spacing 60, the 10% swarm share, and the requester's economics
(`poolBps` 8800, `initialMarketCapWei` 10 ETH, `remainderTo` 0x735121a546092f31050a867fd7e3a750c7b0eff9).
The deployer derives the opening price. Nothing here reads or sets any of these.

Compiler pins (`foundry.toml`): `solc = "0.8.26"`, `evm_version = "cancun"`, optimizer on with
200 runs, `bytecode_hash = "none"` and `cbor_metadata = false` so the built bytecode is
reproducible without a metadata hash. `ffi` is off and `fs_permissions` is empty.

### Reference script

`script/DeploySiphonToken.s.sol` exposes `deploy()` (tested directly) and a `run()` wrapper that
broadcasts it. It is reviewable reference only: the IdentityMD launch deploys the token from its
bytecode through the factory. This repository does not authorise any transaction and contains no
keys.

## After launch

There is nothing to configure. The token has no owner-settable value and no setter.

## Operational responsibilities

- **Supply distribution** is entirely the deployer's. Once the constructor runs, the contract
  cannot move, reclaim or reissue anything. If the deployer's address is lost, so is its balance.
- **No admin recovery.** Tokens sent to the token contract itself, or to any wrong address, are
  unrecoverable by design.
- **No pause.** There is no way to halt transfers in an incident. This is the trade-off for the
  guarantee that no privileged hand can move or freeze a holder's balance.
- **Explorer verification** of the deployed bytecode against this source is the network deployer's
  task after launch.
- Tests passing is not a security audit. The contract is a thin wrapper over OpenZeppelin v5.4.0
  `ERC20`, but an independent adversarial review before anything holds third-party funds is still
  recommended.

## Repository layout

```
foundry.toml                      compiler pins and profile
remappings.txt                    forge-std/ and @openzeppelin/contracts/ to lib/
src/SiphonToken.sol               the token
script/DeploySiphonToken.s.sol    reference deploy script (deploy() is unit-tested)
test/SiphonToken.t.sol            unit, failure-path and fuzz tests
test/SiphonToken.invariant.t.sol  invariant: supply fixed, balances conserve
lib/forge-std                     vendored forge-std v1.9.7 (src only, MIT/Apache-2.0)
lib/openzeppelin-contracts        vendored OpenZeppelin Contracts v5.4.0 (contracts only, MIT)
```

Dependencies are committed as ordinary files, not git submodules, so the project builds offline.

## Running the checks

```
forge build
forge test
forge fmt --check
```

Fuzz tests were run with the verifier's seed:

```
FOUNDRY_FUZZ_SEED=0x5526de621c5595d7aa43e960e292f6a7766d2d06c038914e0783f3b8265a8da3 forge test
```

## Test coverage summary

- Metadata and constants match the brief; supply equals exactly 1e9 * 1e18 and sits wholly with
  the deployer, including when the deployer is a contract (the factory case).
- Constructor emits `Transfer` from the zero address and `SupplyMinted`.
- Transfers: exact amounts, whole balance, zero, self-transfer, chained transfers, conservation.
- Failures: insufficient balance (by one and by fuzzed excess), zero-address receiver, missing and
  exceeded allowance, owner lacking balance, zero spender, deployer cannot pull without allowance.
- Allowances: partial spend decrements, infinite allowance is not decremented.
- Immutability: fourteen common mint/burn/admin/upgrade selectors all revert for both a stranger
  and the deployer with supply and balances untouched; plain ETH is rejected; runtime bytecode
  contains no reachable DELEGATECALL, CALLCODE or SELFDESTRUCT and is under the EIP-170 limit.
- Invariants over random transfer/approve/transferFrom sequences: total supply is fixed and the
  actors' balances always sum to it.
