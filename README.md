# VisualIdentity.md Edition 2

One contract, `VisualIdentityEdition2` (`src/VisualIdentityEdition2.sol`), for Ethereum mainnet (chain id 1).
It is an ERC-721 (name `VisualIdentity.md Edition 2`, symbol `VIMD2`) that runs an open call for the
identity.md agent seats: each seat enters one brand package plus an agent portrait, then each seat casts one
vote, and the whole prize pot goes to the entrant of the leading entry. It has no owner, admin, role,
setting, pause, upgrade, proxy, rescue or sweep. No fungible token, pool or distributor is created; it uses the
existing VIMD token of launch 1645.

## Outside contracts (constants)

| Name | Address | Use |
| --- | --- | --- |
| VIMD (ERC-20, 18 decimals) | `0x931fD96a22BcA8E1008D18ed827D5C042932BE17` | entry fee, vote fee, prize |
| identity.md seats (ERC-721, ids 0..1999) | `0x0000eC93127BAA929E58E97dd0095A2BFb38ec1D` | who may act for a seat |
| delegate.xyz DelegateRegistry v2 | `0x00000000000000447e69651d841bD8D104Bed493` | `checkDelegateForERC721(to, from, seats, seatId, bytes32(0))` |
| Burn address | `0x000000000000000000000000000000000000dEaD` | VIMD is burned by transferring it here |

A caller may act for a seat when it is `ownerOf(seatId)` on the seats contract, or when the registry reports a
live delegation from that owner to the caller for that seat with empty rights. `ownerOf` reverts for an id that
does not exist, so only seats 0..1999 can ever enter or vote.

## Deployment parameters

- Constructor arguments: none.
- The constructor only records `ENTRY_END = deployment + 4 days` and `VOTE_END = deployment + 7 days`. It calls
  no other contract and checks no code length, so it deploys in an empty EVM.
- Compiler pins (`foundry.toml`): solc 0.8.26, optimizer on with 200 runs, evm `cancun`, `bytecode_hash = "none"`,
  `cbor_metadata = false`. Runtime size is about 9.5 KB.
- Dependencies are vendored as plain files under `lib/`: OpenZeppelin Contracts v5.4.0 (`contracts/` only, mocks
  removed) and forge-std v1.11.0 (`src/` only). No submodules.
- The launch deploys from the built bytecode and records the contract under its Solidity name
  `VisualIdentityEdition2`. No `launch.json` is written here; the manifest step writes it.

## Behaviour

Prices are constants: `ENTRY_PRICE = 25,000 VIMD`, `VOTE_PRICE = 50,000 VIMD`, `VOTE_POT_SHARE = 25,000 VIMD`
(the part of a vote kept for the winner; the rest, 25,000, is burned).

### `enter(seatId, portraitJob, portraitHash, portraitURI, packageHash, packageURI) → entryId`

- Only while `block.timestamp < ENTRY_END`, only by someone who may act for the seat, once per seat ever.
- Both links must be 1 to 200 bytes of printable ASCII (`0x21`..`0x7e`) with no `"` and no `\`, else
  `InvalidLink`. They are placed in the tokenURI JSON unescaped, so this rule is what keeps that JSON well formed.
- Stores seat, entrant (`msg.sender`), the IMD image job id, the portrait sha256 and link, the package sha256 and
  link, votes 0. Entry ids start at 1 and are the NFT ids.
- Mints NFT `entryId` to `msg.sender` with `_safeMint` (a contract caller must implement `onERC721Received`),
  then pulls exactly 25,000 VIMD from `msg.sender` to the burn address. The caller must hold and have approved
  at least 25,000 VIMD.
- Emits `Entered`.

### `vote(seatId, entryId)`

- Only while `ENTRY_END <= block.timestamp < VOTE_END`, only by someone who may act for the seat, once per seat
  ever, only for `1 <= entryId <= entryCount`. A seat may vote for any entry, its own included.
- Pulls 50,000 VIMD from `msg.sender`: 25,000 to the burn address, 25,000 to the contract, added to `pot`.
- Adds one vote to the entry and updates the leader. Emits `Voted`.

### `leader() → entryId`

The entry with the most votes; on a tie, the lower id. Reverts `NoVotes` before the first vote. It is tracked
incrementally on each vote (a new vote takes the lead when it has strictly more votes, or equal votes and a lower
id), so no loop over up to 2,000 entries is needed at claim time.

### `claimPrize()`

Anyone, once, when `block.timestamp >= VOTE_END`. Sets `prizeClaimed`, sets `pot` to 0, emits `PrizeClaimed`, then
transfers the whole former pot to the entrant address stored in the leading entry (not the current NFT holder).
Reverts `NoVotes` if nobody voted; the pot is then 0 because only votes fund it.

### `tokenURI(id)`

A `data:application/json;base64,` document built on chain:

```json
{"name":"VisualIdentity.md Edition 2: Agent <seatId>",
 "description":"Portrait of IMD agent <seatId>, drawn by a fellow agent of the swarm, with its owner's brand package for IMD.",
 "image":"<portraitURI>","external_url":"<packageURI>",
 "attributes":[{"trait_type":"Edition","value":"2"},{"trait_type":"Agent","value":"<seatId>"},{"trait_type":"Votes","value":"<votes>"}]}
```

### Views

`entryCount()`, `entry(id)` (every stored field; all zero for an unknown id), `entryOfSeat(seatId)`,
`seatVoted(seatId)`, `pot()`, `totalVotes()`, `prizeClaimed()`, `leader()`, `ENTRY_END`, `VOTE_END`,
`ENTRY_PRICE`, `VOTE_PRICE`, `VOTE_POT_SHARE`, and the four outside addresses.

## Security notes

- `enter`, `vote` and `claimPrize` are `nonReentrant` (OpenZeppelin `ReentrancyGuard`) and follow
  checks-effects-interactions: every state write and event precedes the mint and the VIMD transfers. The receiver
  callback of the mint and any hook in the token cannot re-enter.
- VIMD moves through `SafeERC20`. The only way VIMD leaves the contract is `claimPrize`, which pays exactly
  `pot`, once. There is no `receive` or `fallback`, so ETH cannot be sent to it.
- No `delegatecall`, `selfdestruct`, proxy or external library: the runtime is self-contained.
- The constant leader is read from storage; a vote for a losing entry never changes it.

## Accepted properties (by design, no mechanism added)

1. A seat sold or re-delegated after it entered or voted cannot enter or vote again (`entryOfSeat`,
   `seatVoted` are keyed by seat).
2. A wallet holding or delegated several seats has several entries and several votes, one per seat.
3. The job id, hashes and links are the entrant's own claim; the contract does not check them. The website
   checks them against IMD's public job record.
4. VIMD sent to the contract outside `vote` is not part of `pot` and stays in the contract forever.
5. If nobody votes, nothing is paid and `claimPrize` always reverts.
6. The entrant address is fixed at entry time; selling the NFT does not move the prize.

## Operational responsibilities

- Nobody operates the contract. There is no owner, no settable value and nothing to configure after launch.
- The deployment block fixes `ENTRY_END` and `VOTE_END`. Anyone may call `claimPrize` once voting ends.
- Entrants and voters must approve the contract for VIMD before calling (`25,000e18` for an entry,
  `50,000e18` for a vote). Contract wallets that enter must implement `onERC721Received`.
- Explorer source verification after the launch belongs to the deployer; this task deploys nothing.
- Tests pass but are not an audit; an independent adversarial review is still recommended before release.

## Tests

`test/VisualIdentityEdition2.t.sol` mocks VIMD, the seats and the delegate registry at their mainnet addresses
with `vm.etch` (`test/mocks/`). No fork, no `vm.env*`, no filesystem or ffi. Covered: metadata and constants,
constructor in an empty EVM, entry success by owner and by delegate, every entry failure (window, non-holder,
wrong seat, nonexistent seat, wrong delegation, revoked delegation, duplicate, sold or re-delegated seat,
insufficient VIMD or allowance, each bad link class), fuzzed link rule against a reference, vote success and
every failure (window edges, non-holder, unknown entry, duplicate, sold or re-delegated seat), leader ordering
and a fuzzed scan comparison, prize claim success and failures, donations outside `pot`, VIMD conservation
under fuzzed vote sequences, reentrancy through the mint receiver and through a hooked token on all three
guarded functions, exact tokenURI JSON, and views.

```sh
forge build
forge test
forge fmt --check
```
