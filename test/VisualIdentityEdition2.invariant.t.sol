// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Base64} from "@openzeppelin/contracts/utils/Base64.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";

import {VisualIdentityEdition2} from "../src/VisualIdentityEdition2.sol";
import {MockVIMD} from "./mocks/MockVIMD.sol";
import {MockSeats} from "./mocks/MockSeats.sol";
import {MockDelegateRegistry} from "./mocks/MockDelegateRegistry.sol";

/// @notice Drives VisualIdentityEdition2 with random, bounded call sequences across the whole life of the call:
///         entry window, voting window, claim. Every action is modelled first (who may act, which window, what
///         it costs) and the model's verdict is compared with what the contract did, so an unexpected success is
///         as much a failure as an unexpected revert. Ghost variables record what the contract must hold.
contract Edition2Handler is Test {
    address constant BURN = 0x000000000000000000000000000000000000dEaD;
    uint256 constant ENTRY_PRICE = 25_000e18;
    uint256 constant VOTE_PRICE = 50_000e18;
    uint256 constant POT_SHARE = 25_000e18;

    VisualIdentityEdition2 public immutable call;
    MockVIMD public immutable vimd;
    MockSeats public immutable seats;
    MockDelegateRegistry public immutable registry;

    address[] public actors;
    /// @dev Seat ids the handler plays with. The last two were never minted and must always be rejected.
    uint256[] public seatPool;
    string[] internal _validLinks;
    string[] internal _invalidLinks;

    // ------------------------------------------------------------------ ghosts

    uint256 public ghostEntries;
    uint256 public ghostVotes;
    uint256 public ghostDonations;
    uint256 public ghostPaid;
    address public ghostPaidTo;
    uint256 public ghostClaims;
    uint256 public ghostBurned;
    mapping(uint256 seatId => uint256 entryId) public ghostEntryOfSeat;
    mapping(uint256 seatId => uint256 count) public ghostVoteCountOfSeat;
    mapping(uint256 entryId => uint256 votes) public ghostVotesOfEntry;
    mapping(uint256 entryId => address entrant) public ghostEntrant;
    mapping(uint256 entryId => uint256 seatId) public ghostSeatOfEntry;
    mapping(uint256 entryId => bytes32 digest) public ghostEntryDigest;
    mapping(uint256 entryId => string) public ghostPortraitURI;
    mapping(uint256 entryId => string) public ghostPackageURI;

    // Counters so the test can check the sequences actually exercised every path.
    uint256 public enterOk;
    uint256 public enterRejected;
    uint256 public voteOk;
    uint256 public voteRejected;
    uint256 public claimOk;
    uint256 public claimRejected;
    uint256 public unauthorizedEnterAttempts;
    uint256 public unauthorizedVoteAttempts;
    uint256 public duplicateEnterAttempts;
    uint256 public duplicateVoteAttempts;

    constructor(VisualIdentityEdition2 call_, MockVIMD vimd_, MockSeats seats_, MockDelegateRegistry registry_) {
        call = call_;
        vimd = vimd_;
        seats = seats_;
        registry = registry_;

        for (uint256 i; i < 6; ++i) {
            address a = makeAddr(string.concat("actor", Strings.toString(i)));
            actors.push(a);
            vm.prank(a);
            vimd.approve(address(call), type(uint256).max);
            // actor 5 starts with nothing and only gets VIMD through fund(); its calls must fail on payment.
            if (i < 5) vimd.mint(a, 50_000_000e18);
        }
        // 4 seats each for actors 0..5 (ids 0..23), the last seat id, and two ids that do not exist.
        for (uint256 i; i < 24; ++i) {
            seats.mint(actors[i % 6], i);
            seatPool.push(i);
        }
        seats.mint(actors[0], 1999);
        seatPool.push(1999);
        seatPool.push(2000);
        seatPool.push(777);

        _addLink("ipfs://bafybeigdyrzt5sfp7udm7hu76uh7y26nf3efuylqabf3oclgtqy55fbzdi/portrait.png", true);
        _addLink("https://example.com/brand.zip?x=1&y=<2>#frag", true);
        _addLink("!", true);
        _addLink("~", true);
        _addLink(string(_repeat(0x7e, 200)), true);
        _addLink("", false);
        _addLink(string(_repeat(0x61, 201)), false);
        _addLink("has space", false);
        _addLink('q"uote', false);
        _addLink("back\\slash", false);
        _addLink(unicode"café", false);
        _addLink(string(abi.encodePacked("del", bytes1(0x7f))), false);
    }

    function _addLink(string memory s, bool valid) internal {
        if (valid) _validLinks.push(s);
        else _invalidLinks.push(s);
    }

    /// @dev Three valid links in four, so sequences are not starved of entries; the fourth is an invalid one.
    function _pickLink(uint256 seed) internal view returns (string memory link, bool valid) {
        valid = seed % 4 != 0;
        seed /= 4;
        link = valid ? _validLinks[seed % _validLinks.length] : _invalidLinks[seed % _invalidLinks.length];
    }

    function _repeat(uint8 c, uint256 n) internal pure returns (bytes memory b) {
        b = new bytes(n);
        for (uint256 i; i < n; ++i) {
            b[i] = bytes1(c);
        }
    }

    // ------------------------------------------------------------------ model

    function _seatExists(uint256 seatId) internal view returns (bool) {
        try seats.ownerOf(seatId) returns (address) {
            return true;
        } catch {
            return false;
        }
    }

    function _mayAct(address who, uint256 seatId) internal view returns (bool) {
        if (!_seatExists(seatId)) return false;
        address owner = seats.ownerOf(seatId);
        if (who == owner) return true;
        return registry.checkDelegateForERC721(who, owner, address(seats), seatId, bytes32(0));
    }

    function _canPay(address who, uint256 amount) internal view returns (bool) {
        return vimd.balanceOf(who) >= amount && vimd.allowance(who, address(call)) >= amount;
    }

    // ------------------------------------------------------------------ actions

    struct EnterCtx {
        address actor;
        uint256 seatId;
        string portraitURI;
        string packageURI;
        bytes16 job;
        bytes32 portraitHash;
        bytes32 packageHash;
        bool expected;
        uint256 actorBefore;
        uint256 burnBefore;
        uint256 countBefore;
    }

    function enter(uint256 actorSeed, uint256 seatSeed, uint256 portraitSeed, uint256 packageSeed, bytes32 salt)
        external
    {
        EnterCtx memory c;
        c.actor = actors[bound(actorSeed, 0, actors.length - 1)];
        c.seatId = seatPool[bound(seatSeed, 0, seatPool.length - 1)];
        bool portraitOk;
        bool packageOk;
        (c.portraitURI, portraitOk) = _pickLink(portraitSeed);
        (c.packageURI, packageOk) = _pickLink(packageSeed);

        bool mayAct = _mayAct(c.actor, c.seatId);
        bool already = ghostEntryOfSeat[c.seatId] != 0;
        c.expected = block.timestamp < call.ENTRY_END() && mayAct && !already && portraitOk && packageOk
            && _canPay(c.actor, ENTRY_PRICE);
        if (!mayAct) ++unauthorizedEnterAttempts;
        if (already) ++duplicateEnterAttempts;

        c.actorBefore = vimd.balanceOf(c.actor);
        c.burnBefore = vimd.balanceOf(BURN);
        c.countBefore = call.entryCount();
        c.job = bytes16(salt);
        c.portraitHash = keccak256(abi.encode("portrait", salt));
        c.packageHash = keccak256(abi.encode("package", salt));

        vm.prank(c.actor);
        try call.enter(c.seatId, c.job, c.portraitHash, c.portraitURI, c.packageHash, c.packageURI) returns (
            uint256 id
        ) {
            _afterEnterOk(c, id);
        } catch {
            assertFalse(c.expected, "enter reverted although the model allows it");
            assertEq(call.entryCount(), c.countBefore, "a failed entry leaves no entry");
            assertEq(vimd.balanceOf(c.actor), c.actorBefore, "a failed entry costs nothing");
            ++enterRejected;
        }
    }

    function _afterEnterOk(EnterCtx memory c, uint256 id) internal {
        assertTrue(c.expected, "enter succeeded although the model forbids it");
        assertEq(id, c.countBefore + 1, "entry ids are sequential");
        assertEq(call.ownerOf(id), c.actor, "NFT minted to the caller");
        assertEq(vimd.balanceOf(c.actor), c.actorBefore - ENTRY_PRICE, "entry costs exactly ENTRY_PRICE");
        assertEq(vimd.balanceOf(BURN), c.burnBefore + ENTRY_PRICE, "entry fee is burned");
        ++enterOk;
        ++ghostEntries;
        ghostBurned += ENTRY_PRICE;
        ghostEntryOfSeat[c.seatId] = id;
        ghostEntrant[id] = c.actor;
        ghostSeatOfEntry[id] = c.seatId;
        ghostPortraitURI[id] = c.portraitURI;
        ghostPackageURI[id] = c.packageURI;
        ghostEntryDigest[id] =
            keccak256(abi.encode(c.seatId, c.actor, c.job, c.portraitHash, c.portraitURI, c.packageHash, c.packageURI));
    }

    function vote(uint256 actorSeed, uint256 seatSeed, uint256 entrySeed) external {
        address actor = actors[bound(actorSeed, 0, actors.length - 1)];
        uint256 seatId = seatPool[bound(seatSeed, 0, seatPool.length - 1)];
        // Mostly existing entries, sometimes 0 or one past the end.
        uint256 entryId = bound(entrySeed, 0, call.entryCount() + 1);

        bool mayAct = _mayAct(actor, seatId);
        bool already = ghostVoteCountOfSeat[seatId] != 0;
        bool inWindow = block.timestamp >= call.ENTRY_END() && block.timestamp < call.VOTE_END();
        bool exists = entryId != 0 && entryId <= ghostEntries;
        bool expected = inWindow && mayAct && !already && exists && _canPay(actor, VOTE_PRICE);
        if (!mayAct) ++unauthorizedVoteAttempts;
        if (already) ++duplicateVoteAttempts;

        uint256 actorBefore = vimd.balanceOf(actor);
        uint256 burnBefore = vimd.balanceOf(BURN);
        uint256 heldBefore = vimd.balanceOf(address(call));
        uint256 potBefore = call.pot();
        uint256 votesBefore = exists ? call.entry(entryId).votes : 0;

        vm.prank(actor);
        try call.vote(seatId, entryId) {
            assertTrue(expected, "vote succeeded although the model forbids it");
            assertEq(vimd.balanceOf(actor), actorBefore - VOTE_PRICE, "vote costs exactly VOTE_PRICE");
            assertEq(vimd.balanceOf(BURN), burnBefore + VOTE_PRICE - POT_SHARE, "half of a vote is burned");
            assertEq(vimd.balanceOf(address(call)), heldBefore + POT_SHARE, "half of a vote stays");
            assertEq(call.pot(), potBefore + POT_SHARE, "pot grows by POT_SHARE");
            assertEq(call.entry(entryId).votes, votesBefore + 1, "one vote added");
            assertTrue(call.seatVoted(seatId));
            ++voteOk;
            ++ghostVotes;
            ghostBurned += VOTE_PRICE - POT_SHARE;
            ++ghostVoteCountOfSeat[seatId];
            ++ghostVotesOfEntry[entryId];
        } catch {
            assertFalse(expected, "vote reverted although the model allows it");
            assertEq(call.pot(), potBefore, "a failed vote leaves pot alone");
            assertEq(vimd.balanceOf(address(call)), heldBefore, "a failed vote moves nothing in");
            assertEq(vimd.balanceOf(actor), actorBefore, "a failed vote costs nothing");
            if (exists) assertEq(call.entry(entryId).votes, votesBefore, "a failed vote adds nothing");
            ++voteRejected;
        }
    }

    function claimPrize(uint256 actorSeed) external {
        address actor = actors[bound(actorSeed, 0, actors.length - 1)];
        bool expected = block.timestamp >= call.VOTE_END() && !call.prizeClaimed() && ghostVotes > 0;

        uint256 potBefore = call.pot();
        uint256 heldBefore = vimd.balanceOf(address(call));
        address winner;
        uint256 winnerBefore;
        if (ghostVotes > 0) {
            winner = call.entry(call.leader()).entrant;
            winnerBefore = vimd.balanceOf(winner);
        }

        vm.prank(actor);
        try call.claimPrize() {
            assertTrue(expected, "claimPrize succeeded although the model forbids it");
            assertEq(potBefore, ghostVotes * POT_SHARE, "pot paid is exactly what the votes left");
            assertEq(vimd.balanceOf(winner), winnerBefore + potBefore, "winner receives the whole pot");
            assertEq(vimd.balanceOf(address(call)), heldBefore - potBefore, "exactly pot left the contract");
            assertEq(call.pot(), 0, "pot is 0 after the claim");
            assertTrue(call.prizeClaimed());
            ++claimOk;
            ++ghostClaims;
            ghostPaid += potBefore;
            ghostPaidTo = winner;
        } catch {
            assertFalse(expected, "claimPrize reverted although the model allows it");
            assertEq(call.pot(), potBefore, "a failed claim leaves pot alone");
            assertEq(vimd.balanceOf(address(call)), heldBefore, "a failed claim moves nothing");
            ++claimRejected;
        }
    }

    // ------------------------------------------------------------------ world changes

    /// @dev Moves time forward by up to 18 hours, so a sequence walks through entry, voting and claim.
    function warp(uint256 delta) external {
        vm.warp(block.timestamp + bound(delta, 0, 18 hours));
    }

    /// @dev Jumps exactly to a window boundary, so off-by-one checks at ENTRY_END and VOTE_END are exercised.
    ///      Gated so a run has entries before voting opens and votes before it closes; plain warp() still
    ///      reaches the boundaries without that, so the empty paths are not excluded.
    function warpToBoundary(bool voteEnd) external {
        uint256 target = voteEnd ? call.VOTE_END() : call.ENTRY_END();
        if (block.timestamp >= target) return;
        if (voteEnd && (block.timestamp < call.ENTRY_END() || ghostVotes == 0)) return;
        if (!voteEnd && ghostEntries == 0) return;
        vm.warp(target);
    }

    /// @dev A seat changes hands. The seat's entry and vote stay used up.
    function sellSeat(uint256 seatSeed, uint256 toSeed) external {
        uint256 seatId = seatPool[bound(seatSeed, 0, seatPool.length - 1)];
        if (!_seatExists(seatId)) return;
        address owner = seats.ownerOf(seatId);
        address to = actors[bound(toSeed, 0, actors.length - 1)];
        if (to == owner) return;
        vm.prank(owner);
        seats.transferFrom(owner, to, seatId);
    }

    /// @dev The current owner of a seat grants or revokes a delegation to another actor.
    function delegate(uint256 seatSeed, uint256 toSeed, bool on) external {
        uint256 seatId = seatPool[bound(seatSeed, 0, seatPool.length - 1)];
        if (!_seatExists(seatId)) return;
        address owner = seats.ownerOf(seatId);
        address to = actors[bound(toSeed, 0, actors.length - 1)];
        registry.setDelegate(to, owner, address(seats), seatId, bytes32(0), on);
    }

    /// @dev A stale delegation: granted by an actor who is not (or no longer) the seat's owner.
    function staleDelegate(uint256 seatSeed, uint256 fromSeed, uint256 toSeed) external {
        uint256 seatId = seatPool[bound(seatSeed, 0, seatPool.length - 1)];
        address from = actors[bound(fromSeed, 0, actors.length - 1)];
        address to = actors[bound(toSeed, 0, actors.length - 1)];
        registry.setDelegate(to, from, address(seats), seatId, bytes32(0), true);
    }

    /// @dev VIMD sent to the contract outside vote. Must never join pot and must never leave.
    function donate(uint256 amount) external {
        amount = bound(amount, 1, 1_000_000e18);
        vimd.mint(address(call), amount);
        ghostDonations += amount;
    }

    function fund(uint256 actorSeed, uint256 amount) external {
        address actor = actors[bound(actorSeed, 0, actors.length - 1)];
        vimd.mint(actor, bound(amount, 0, 1_000_000e18));
    }

    /// @dev The entry NFT changes hands. The stored entrant must not change.
    function transferEntryNFT(uint256 entrySeed, uint256 toSeed) external {
        if (ghostEntries == 0) return;
        uint256 id = bound(entrySeed, 1, ghostEntries);
        address owner = call.ownerOf(id);
        address to = actors[bound(toSeed, 0, actors.length - 1)];
        if (to == owner) return;
        vm.prank(owner);
        call.transferFrom(owner, to, id);
    }

    // ------------------------------------------------------------------ helpers for invariants

    function actorCount() external view returns (uint256) {
        return actors.length;
    }

    function seatPoolLength() external view returns (uint256) {
        return seatPool.length;
    }

    function expectedTokenURI(uint256 id) external view returns (string memory) {
        string memory seat = Strings.toString(ghostSeatOfEntry[id]);
        bytes memory json = bytes.concat(
            '{"name":"VisualIdentity.md Edition 2: Agent ',
            bytes(seat),
            '","description":"Portrait of IMD agent ',
            bytes(seat),
            ", drawn by a fellow agent of the swarm, with its owner's brand package for IMD.",
            '","image":"',
            bytes(ghostPortraitURI[id]),
            '","external_url":"',
            bytes(ghostPackageURI[id]),
            '","attributes":[{"trait_type":"Edition","value":"2"},{"trait_type":"Agent","value":"',
            bytes(seat),
            '"},{"trait_type":"Votes","value":"',
            bytes(Strings.toString(ghostVotesOfEntry[id])),
            '"}]}'
        );
        return string.concat("data:application/json;base64,", Base64.encode(json));
    }
}

/// forge-config: default.invariant.runs = 96
/// forge-config: default.invariant.depth = 120
/// forge-config: default.invariant.fail-on-revert = true
contract VisualIdentityEdition2InvariantTest is Test {
    address constant VIMD_ADDR = 0x931fD96a22BcA8E1008D18ed827D5C042932BE17;
    address constant SEATS_ADDR = 0x0000eC93127BAA929E58E97dd0095A2BFb38ec1D;
    address constant REGISTRY_ADDR = 0x00000000000000447e69651d841bD8D104Bed493;
    address constant BURN = 0x000000000000000000000000000000000000dEaD;
    uint256 constant ENTRY_PRICE = 25_000e18;
    uint256 constant VOTE_PRICE = 50_000e18;
    uint256 constant POT_SHARE = 25_000e18;

    MockVIMD vimd = MockVIMD(VIMD_ADDR);
    MockSeats seats = MockSeats(SEATS_ADDR);
    MockDelegateRegistry registry = MockDelegateRegistry(REGISTRY_ADDR);
    VisualIdentityEdition2 call;
    Edition2Handler handler;

    function setUp() public {
        vm.etch(VIMD_ADDR, type(MockVIMD).runtimeCode);
        vm.etch(SEATS_ADDR, type(MockSeats).runtimeCode);
        vm.etch(REGISTRY_ADDR, type(MockDelegateRegistry).runtimeCode);
        vm.warp(1_800_000_000);
        call = new VisualIdentityEdition2();
        handler = new Edition2Handler(call, vimd, seats, registry);

        targetContract(address(handler));
        bytes4[] memory selectors = new bytes4[](13);
        selectors[0] = Edition2Handler.enter.selector;
        selectors[1] = Edition2Handler.enter.selector; // weighted: entries are the base of everything else
        selectors[2] = Edition2Handler.vote.selector;
        selectors[3] = Edition2Handler.vote.selector;
        selectors[4] = Edition2Handler.claimPrize.selector;
        selectors[5] = Edition2Handler.warp.selector;
        selectors[6] = Edition2Handler.warpToBoundary.selector;
        selectors[7] = Edition2Handler.sellSeat.selector;
        selectors[8] = Edition2Handler.delegate.selector;
        selectors[9] = Edition2Handler.staleDelegate.selector;
        selectors[10] = Edition2Handler.donate.selector;
        selectors[11] = Edition2Handler.transferEntryNFT.selector;
        selectors[12] = Edition2Handler.fund.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
    }

    // ------------------------------------------------------------------ conservation

    /// @notice What the contract holds is exactly pot plus VIMD sent to it outside vote: nothing else ever leaves.
    function invariant_contractHoldsPotPlusDonations() public view {
        assertEq(vimd.balanceOf(address(call)), call.pot() + handler.ghostDonations());
    }

    /// @notice pot is POT_SHARE per vote until the claim, then 0; donations never join it.
    function invariant_potIsVoteSharesUntilClaimed() public view {
        uint256 expected = call.prizeClaimed() ? 0 : call.totalVotes() * POT_SHARE;
        assertEq(call.pot(), expected);
    }

    /// @notice Everything burned is ENTRY_PRICE per entry plus half of VOTE_PRICE per vote.
    function invariant_burnMatchesEntriesAndVotes() public view {
        assertEq(vimd.balanceOf(BURN), call.entryCount() * ENTRY_PRICE + call.totalVotes() * (VOTE_PRICE - POT_SHARE));
        assertEq(vimd.balanceOf(BURN), handler.ghostBurned());
    }

    /// @notice VIMD leaves the contract only through claimPrize, once, paying exactly the votes' pot to the leader.
    function invariant_onlyClaimPaysAndOnlyOnce() public view {
        assertLe(handler.ghostClaims(), 1);
        if (handler.ghostClaims() == 0) {
            assertEq(handler.ghostPaid(), 0);
            assertFalse(call.prizeClaimed());
        } else {
            assertTrue(call.prizeClaimed());
            assertEq(handler.ghostPaid(), call.totalVotes() * POT_SHARE);
            assertEq(handler.ghostPaidTo(), call.entry(call.leader()).entrant);
            assertEq(call.pot(), 0);
        }
    }

    /// @notice A claim can only have happened at or after VOTE_END, and only if someone voted.
    function invariant_claimOnlyAfterVoteEndWithVotes() public view {
        if (call.prizeClaimed()) {
            assertGe(block.timestamp, call.VOTE_END());
            assertGt(call.totalVotes(), 0);
        }
    }

    // ------------------------------------------------------------------ counting

    /// @notice The contract's counters agree with the ghosts, and votes per entry sum to totalVotes.
    function invariant_countersMatchGhosts() public view {
        assertEq(call.entryCount(), handler.ghostEntries());
        assertEq(call.totalVotes(), handler.ghostVotes());
        uint256 sum;
        for (uint256 id = 1; id <= call.entryCount(); ++id) {
            uint256 v = call.entry(id).votes;
            assertEq(v, handler.ghostVotesOfEntry(id));
            sum += v;
        }
        assertEq(sum, call.totalVotes());
    }

    /// @notice One entry and one vote per seat, ever: seats map to at most one entry, no seat votes twice,
    ///         and every entry's seat maps back to it.
    function invariant_onePerSeat() public view {
        uint256 n = handler.seatPoolLength();
        for (uint256 i; i < n; ++i) {
            uint256 seatId = handler.seatPool(i);
            assertEq(call.entryOfSeat(seatId), handler.ghostEntryOfSeat(seatId));
            assertLe(handler.ghostVoteCountOfSeat(seatId), 1);
            assertEq(call.seatVoted(seatId), handler.ghostVoteCountOfSeat(seatId) == 1);
            if (seatId >= 2000 || seatId == 777) {
                assertEq(call.entryOfSeat(seatId), 0, "a seat that does not exist never enters");
                assertFalse(call.seatVoted(seatId), "a seat that does not exist never votes");
            }
        }
        for (uint256 id = 1; id <= call.entryCount(); ++id) {
            assertEq(call.entryOfSeat(call.entry(id).seatId), id);
        }
    }

    /// @notice No entry after ENTRY_END and no vote outside [ENTRY_END, VOTE_END) can have happened: the ghosts
    ///         only count what succeeded, and the handler asserts the window on each success through its model.
    ///         Here: before ENTRY_END there can be no vote at all.
    function invariant_noVoteBeforeEntryEnd() public view {
        if (block.timestamp < call.ENTRY_END()) {
            assertEq(call.totalVotes(), 0);
            assertEq(call.pot(), 0);
            assertFalse(call.prizeClaimed());
        }
    }

    // ------------------------------------------------------------------ entries and NFTs

    /// @notice Every entry id is a minted NFT, the stored fields never change after entry, and the entrant is the
    ///         caller who entered, whoever holds the NFT now.
    function invariant_entriesAreImmutableAndMinted() public view {
        uint256 n = call.entryCount();
        for (uint256 id = 1; id <= n; ++id) {
            VisualIdentityEdition2.Entry memory e = call.entry(id);
            assertEq(
                keccak256(
                    abi.encode(
                        e.seatId, e.entrant, e.portraitJob, e.portraitHash, e.portraitURI, e.packageHash, e.packageURI
                    )
                ),
                handler.ghostEntryDigest(id)
            );
            assertEq(e.entrant, handler.ghostEntrant(id));
            assertNotEq(call.ownerOf(id), address(0));
        }
        // nothing beyond entryCount exists
        assertEq(call.entry(n + 1).entrant, address(0));
        (bool ok,) = address(call).staticcall(abi.encodeCall(call.ownerOf, (n + 1)));
        assertFalse(ok, "no NFT beyond entryCount");
        (ok,) = address(call).staticcall(abi.encodeCall(call.ownerOf, (0)));
        assertFalse(ok, "no NFT 0");
    }

    /// @notice NFT balances across actors sum to entryCount: one NFT per entry, none created elsewhere.
    function invariant_nftSupplyIsEntryCount() public view {
        uint256 sum;
        for (uint256 i; i < handler.actorCount(); ++i) {
            sum += call.balanceOf(handler.actors(i));
        }
        assertEq(sum, call.entryCount());
    }

    /// @notice The leader is the entry with the most votes, lowest id on a tie, and is unreadable before a vote.
    function invariant_leaderMatchesScan() public {
        if (call.totalVotes() == 0) {
            vm.expectRevert(VisualIdentityEdition2.NoVotes.selector);
            call.leader();
            return;
        }
        uint256 best;
        uint256 bestVotes;
        for (uint256 id = 1; id <= call.entryCount(); ++id) {
            uint256 v = call.entry(id).votes;
            if (v > bestVotes) {
                bestVotes = v;
                best = id;
            }
        }
        assertEq(call.leader(), best);
    }

    /// @notice tokenURI is exactly the on-chain JSON the brief specifies, for every entry, with live votes.
    function invariant_tokenURIMatchesSpec() public view {
        for (uint256 id = 1; id <= call.entryCount(); ++id) {
            assertEq(call.tokenURI(id), handler.expectedTokenURI(id));
        }
    }

    /// @notice The times never move.
    function invariant_timesAreFixed() public view {
        assertEq(call.ENTRY_END(), 1_800_000_000 + 4 days);
        assertEq(call.VOTE_END(), 1_800_000_000 + 7 days);
    }

    // ------------------------------------------------------------------ non-vacuity

    function _checkAllInvariants() internal {
        invariant_contractHoldsPotPlusDonations();
        invariant_potIsVoteSharesUntilClaimed();
        invariant_burnMatchesEntriesAndVotes();
        invariant_onlyClaimPaysAndOnlyOnce();
        invariant_claimOnlyAfterVoteEndWithVotes();
        invariant_countersMatchGhosts();
        invariant_onePerSeat();
        invariant_noVoteBeforeEntryEnd();
        invariant_entriesAreImmutableAndMinted();
        invariant_nftSupplyIsEntryCount();
        invariant_leaderMatchesScan();
        invariant_tokenURIMatchesSpec();
        invariant_timesAreFixed();
    }

    /// @notice A scripted walk through the whole life of the call, with the handler's model checking each step
    ///         and every invariant checked after each phase. It proves the handler reaches every path (success
    ///         and rejection of enter, vote and claim; sold and delegated seats; donations; NFT transfers), so
    ///         the random runs above are not vacuous, without depending on what a random run happened to do.
    function test_handlerScriptedLifecycleHoldsEveryInvariant() public {
        // seat ids: actor i owns seats i, i+6, i+12, i+18; seatPool index == seat id for 0..23; 24 -> 1999;
        // 25 -> 2000 (absent); 26 -> 777 (absent). Link seeds: 1 is valid, 0 is invalid.
        handler.enter(0, 0, 1, 1, bytes32(uint256(1))); // ok: actor0, seat 0
        handler.enter(1, 1, 1, 1, bytes32(uint256(2))); // ok: actor1, seat 1
        handler.enter(0, 1, 1, 1, bytes32(uint256(3))); // rejected: not holder
        handler.enter(0, 0, 1, 1, bytes32(uint256(4))); // rejected: seat 0 already entered
        handler.enter(0, 25, 1, 1, bytes32(uint256(5))); // rejected: seat 2000 does not exist
        handler.enter(0, 6, 0, 1, bytes32(uint256(6))); // rejected: invalid portrait link
        handler.enter(5, 5, 1, 1, bytes32(uint256(7))); // rejected: actor5 has no VIMD
        handler.delegate(2, 0, true); // actor2 delegates seat 2 to actor0
        handler.enter(0, 2, 1, 1, bytes32(uint256(8))); // ok: by delegate
        handler.staleDelegate(3, 0, 1); // actor0 (not owner) "delegates" seat 3 to actor1
        handler.enter(1, 3, 1, 1, bytes32(uint256(9))); // rejected: stale delegation
        handler.sellSeat(0, 4); // seat 0 moves to actor4
        handler.enter(4, 0, 1, 1, bytes32(uint256(10))); // rejected: seat 0 already entered before the sale
        handler.vote(1, 7, 1); // rejected: voting not open
        handler.donate(123e18);
        handler.transferEntryNFT(1, 3); // NFT 1 to actor3; entrant stays actor0
        _checkAllInvariants();
        assertEq(handler.enterOk(), 3);
        assertEq(handler.enterRejected(), 7);

        handler.warpToBoundary(false); // exactly ENTRY_END
        handler.enter(3, 3, 1, 1, bytes32(uint256(11))); // rejected: entries closed
        handler.vote(0, 6, 2); // ok: actor0 seat 6 -> entry 2
        handler.vote(0, 12, 2); // ok: several seats, several votes
        handler.vote(0, 12, 1); // rejected: seat 12 already voted
        handler.vote(1, 7, 1); // ok -> entry 1 (1 vote); leader stays 2
        handler.vote(1, 13, 0); // rejected: entry 0
        handler.vote(1, 13, 99); // rejected: unknown entry
        handler.vote(2, 8, 3); // ok -> entry 3
        handler.vote(2, 25, 1); // rejected: seat 2000
        handler.vote(5, 5, 1); // rejected: no VIMD
        handler.fund(5, 1_000_000e18);
        handler.vote(5, 5, 1); // ok, now funded -> entry 1 (2 votes): tie with 2, lower id leads
        handler.sellSeat(5, 1); // seat 5 to actor1
        handler.vote(1, 5, 1); // rejected: seat 5 already voted
        handler.claimPrize(0); // rejected: voting not over
        _checkAllInvariants();
        assertEq(call.leader(), 1);
        assertEq(handler.voteOk(), 5);
        assertEq(handler.voteRejected(), 7);

        handler.warpToBoundary(true); // exactly VOTE_END
        handler.vote(3, 9, 1); // rejected: voting closed
        uint256 winnerBefore = vimd.balanceOf(handler.actors(0));
        handler.claimPrize(4); // ok: anyone; pays actor0 (entrant of 1), not actor3 (holder of NFT 1)
        assertEq(vimd.balanceOf(handler.actors(0)), winnerBefore + 5 * POT_SHARE);
        handler.claimPrize(0); // rejected: already claimed
        handler.donate(1e18);
        _checkAllInvariants();
        assertEq(handler.claimOk(), 1);
        assertEq(handler.claimRejected(), 2);
        assertEq(vimd.balanceOf(address(call)), 124e18, "donations stay, nothing else does");
    }
}
