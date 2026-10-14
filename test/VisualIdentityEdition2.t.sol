// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC721Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Base64} from "@openzeppelin/contracts/utils/Base64.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";

import {VisualIdentityEdition2} from "../src/VisualIdentityEdition2.sol";
import {MockVIMD} from "./mocks/MockVIMD.sol";
import {MockSeats} from "./mocks/MockSeats.sol";
import {MockDelegateRegistry} from "./mocks/MockDelegateRegistry.sol";
import {ReentrantReceiver, ReentrantVIMD} from "./mocks/Attackers.sol";

contract VisualIdentityEdition2Test is Test {
    address constant VIMD_ADDR = 0x931fD96a22BcA8E1008D18ed827D5C042932BE17;
    address constant SEATS_ADDR = 0x0000eC93127BAA929E58E97dd0095A2BFb38ec1D;
    address constant REGISTRY_ADDR = 0x00000000000000447e69651d841bD8D104Bed493;
    address constant BURN = 0x000000000000000000000000000000000000dEaD;

    uint256 constant ENTRY_PRICE = 25_000e18;
    uint256 constant VOTE_PRICE = 50_000e18;
    uint256 constant POT_SHARE = 25_000e18;
    uint256 constant FUND = 1_000_000e18;

    MockVIMD vimd = MockVIMD(VIMD_ADDR);
    MockSeats seats = MockSeats(SEATS_ADDR);
    MockDelegateRegistry registry = MockDelegateRegistry(REGISTRY_ADDR);
    VisualIdentityEdition2 call;

    uint256 deployedAt;

    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address carol = makeAddr("carol");
    address dave = makeAddr("dave");
    address stranger = makeAddr("stranger");

    function setUp() public {
        vm.etch(VIMD_ADDR, type(MockVIMD).runtimeCode);
        vm.etch(SEATS_ADDR, type(MockSeats).runtimeCode);
        vm.etch(REGISTRY_ADDR, type(MockDelegateRegistry).runtimeCode);
        vm.label(VIMD_ADDR, "VIMD");
        vm.label(SEATS_ADDR, "Seats");
        vm.label(REGISTRY_ADDR, "DelegateRegistry");

        vm.warp(1_800_000_000);
        deployedAt = block.timestamp;
        call = new VisualIdentityEdition2();

        seats.mint(alice, 0);
        seats.mint(alice, 1);
        seats.mint(bob, 2);
        seats.mint(carol, 3);
        seats.mint(dave, 1999);

        address[5] memory users = [alice, bob, carol, dave, stranger];
        for (uint256 i; i < users.length; ++i) {
            vimd.mint(users[i], FUND);
            vm.prank(users[i]);
            vimd.approve(address(call), type(uint256).max);
        }
    }

    // ------------------------------------------------------------------ helpers

    function _enter(address who, uint256 seatId) internal returns (uint256 id) {
        vm.prank(who);
        id = call.enter(
            seatId,
            bytes16(uint128(seatId + 1)),
            keccak256(abi.encode("portrait", seatId)),
            string.concat("ipfs://portrait/", Strings.toString(seatId)),
            keccak256(abi.encode("package", seatId)),
            string.concat("https://example.com/package/", Strings.toString(seatId), ".zip")
        );
    }

    function _vote(address who, uint256 seatId, uint256 entryId) internal {
        vm.prank(who);
        call.vote(seatId, entryId);
    }

    function _openVoting() internal {
        vm.warp(call.ENTRY_END());
    }

    function _closeVoting() internal {
        vm.warp(call.VOTE_END());
    }

    function _delegate(address to, address from, uint256 seatId, bool on) internal {
        registry.setDelegate(to, from, SEATS_ADDR, seatId, bytes32(0), on);
    }

    // ------------------------------------------------------------------ deployment

    function test_metadataAndConstants() public view {
        assertEq(call.name(), "VisualIdentity.md Edition 2");
        assertEq(call.symbol(), "VIMD2");
        assertEq(call.entryCount(), 0);
        assertEq(call.pot(), 0);
        assertEq(call.totalVotes(), 0);
        assertFalse(call.prizeClaimed());
        assertEq(call.ENTRY_END(), deployedAt + 4 days);
        assertEq(call.VOTE_END(), deployedAt + 7 days);
        assertEq(call.ENTRY_PRICE(), ENTRY_PRICE);
        assertEq(call.VOTE_PRICE(), VOTE_PRICE);
        assertEq(call.VOTE_POT_SHARE(), POT_SHARE);
        assertEq(address(call.VIMD()), VIMD_ADDR);
        assertEq(address(call.SEATS()), SEATS_ADDR);
        assertEq(address(call.DELEGATE_REGISTRY()), REGISTRY_ADDR);
        assertEq(call.BURN_ADDRESS(), BURN);
    }

    function test_constructorNeedsNoOtherContract() public {
        // Deploy in an EVM where the outside contracts have no code, as the launch checks do.
        vm.etch(VIMD_ADDR, "");
        vm.etch(SEATS_ADDR, "");
        vm.etch(REGISTRY_ADDR, "");
        vm.warp(12_345);
        VisualIdentityEdition2 fresh = new VisualIdentityEdition2();
        assertEq(fresh.ENTRY_END(), 12_345 + 4 days);
        assertEq(fresh.VOTE_END(), 12_345 + 7 days);
        assertLe(address(fresh).code.length, 24_576);
    }

    function test_noOwnerOrAdminSurface() public {
        (bool ok,) = address(call).call(abi.encodeWithSignature("owner()"));
        assertFalse(ok, "owner() must not exist");
        (ok,) = address(call).call(abi.encodeWithSignature("pause()"));
        assertFalse(ok, "pause() must not exist");
    }

    // ------------------------------------------------------------------ enter: success

    function test_enter_byOwnerStoresMintsAndBurns() public {
        uint256 burnBefore = vimd.balanceOf(BURN);
        uint256 aliceBefore = vimd.balanceOf(alice);

        vm.expectEmit(address(call));
        emit VisualIdentityEdition2.Entered(
            1,
            0,
            alice,
            bytes16(uint128(1)),
            keccak256(abi.encode("portrait", uint256(0))),
            "ipfs://portrait/0",
            keccak256(abi.encode("package", uint256(0))),
            "https://example.com/package/0.zip"
        );
        uint256 id = _enter(alice, 0);

        assertEq(id, 1);
        assertEq(call.entryCount(), 1);
        assertEq(call.entryOfSeat(0), 1);
        assertEq(call.ownerOf(1), alice);
        assertEq(call.balanceOf(alice), 1);
        assertEq(vimd.balanceOf(BURN), burnBefore + ENTRY_PRICE);
        assertEq(vimd.balanceOf(alice), aliceBefore - ENTRY_PRICE);
        assertEq(vimd.balanceOf(address(call)), 0, "entry fee never stays in the contract");

        VisualIdentityEdition2.Entry memory e = call.entry(1);
        assertEq(e.seatId, 0);
        assertEq(e.entrant, alice);
        assertEq(e.portraitJob, bytes16(uint128(1)));
        assertEq(e.portraitHash, keccak256(abi.encode("portrait", uint256(0))));
        assertEq(e.portraitURI, "ipfs://portrait/0");
        assertEq(e.packageHash, keccak256(abi.encode("package", uint256(0))));
        assertEq(e.packageURI, "https://example.com/package/0.zip");
        assertEq(e.votes, 0);
    }

    function test_enter_idsAreSequentialAndOnePerSeat() public {
        assertEq(_enter(alice, 0), 1);
        assertEq(_enter(alice, 1), 2);
        assertEq(_enter(bob, 2), 3);
        assertEq(_enter(dave, 1999), 4);
        assertEq(call.entryCount(), 4);
        assertEq(call.balanceOf(alice), 2);
        assertEq(call.entryOfSeat(1999), 4);
        assertEq(call.entry(4).seatId, 1999);
    }

    function test_enter_byDelegate() public {
        _delegate(stranger, alice, 0, true);
        uint256 strangerBefore = vimd.balanceOf(stranger);
        uint256 id = _enter(stranger, 0);
        assertEq(call.ownerOf(id), stranger, "NFT goes to msg.sender, the delegate");
        assertEq(call.entry(id).entrant, stranger);
        assertEq(vimd.balanceOf(stranger), strangerBefore - ENTRY_PRICE, "the delegate pays");
    }

    function test_enter_justBeforeEntryEnd() public {
        vm.warp(call.ENTRY_END() - 1);
        assertEq(_enter(alice, 0), 1);
    }

    function test_enter_acceptsEdgePrintableAsciiAndMaxLength() public {
        bytes memory maxLink = new bytes(200);
        for (uint256 i; i < 200; ++i) {
            maxLink[i] = bytes1(uint8(0x21 + (i % 2) * (0x7e - 0x21)));
        }
        vm.prank(alice);
        uint256 id = call.enter(0, bytes16(0), bytes32(0), string(maxLink), bytes32(0), "!");
        assertEq(call.entry(id).portraitURI, string(maxLink));
        assertEq(call.entry(id).packageURI, "!");
    }

    // ------------------------------------------------------------------ enter: failure

    function test_enter_revertsAtEntryEnd() public {
        vm.warp(call.ENTRY_END());
        vm.expectRevert(VisualIdentityEdition2.EntryClosed.selector);
        _enter(alice, 0);
    }

    function test_enter_revertsForNonHolder() public {
        vm.expectRevert(abi.encodeWithSelector(VisualIdentityEdition2.NotSeatHolder.selector, 0, stranger));
        _enter(stranger, 0);
    }

    function test_enter_revertsForHolderOfAnotherSeat() public {
        vm.expectRevert(abi.encodeWithSelector(VisualIdentityEdition2.NotSeatHolder.selector, 2, alice));
        _enter(alice, 2);
    }

    function test_enter_revertsForNonexistentSeat() public {
        vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721NonexistentToken.selector, 2000));
        _enter(alice, 2000);
    }

    function test_enter_delegationForOtherSeatOrRightsDoesNotCount() public {
        _delegate(stranger, alice, 1, true); // seat 1, not seat 0
        vm.expectRevert(abi.encodeWithSelector(VisualIdentityEdition2.NotSeatHolder.selector, 0, stranger));
        _enter(stranger, 0);

        registry.setDelegate(stranger, alice, SEATS_ADDR, 0, bytes32("other"), true); // wrong rights
        vm.expectRevert(abi.encodeWithSelector(VisualIdentityEdition2.NotSeatHolder.selector, 0, stranger));
        _enter(stranger, 0);

        _delegate(stranger, bob, 0, true); // from someone who is not the owner
        vm.expectRevert(abi.encodeWithSelector(VisualIdentityEdition2.NotSeatHolder.selector, 0, stranger));
        _enter(stranger, 0);
    }

    function test_enter_revokedDelegationDoesNotCount() public {
        _delegate(stranger, alice, 0, true);
        _delegate(stranger, alice, 0, false);
        vm.expectRevert(abi.encodeWithSelector(VisualIdentityEdition2.NotSeatHolder.selector, 0, stranger));
        _enter(stranger, 0);
    }

    function test_enter_revertsOnSecondEntryForSeat() public {
        _enter(alice, 0);
        vm.expectRevert(abi.encodeWithSelector(VisualIdentityEdition2.SeatAlreadyEntered.selector, 0));
        _enter(alice, 0);
    }

    function test_enter_seatSoldAfterEntryCannotEnterAgain() public {
        _enter(alice, 0);
        vm.prank(alice);
        seats.transferFrom(alice, bob, 0);
        vm.expectRevert(abi.encodeWithSelector(VisualIdentityEdition2.SeatAlreadyEntered.selector, 0));
        _enter(bob, 0);
    }

    function test_enter_seatRedelegatedAfterEntryCannotEnterAgain() public {
        _delegate(stranger, alice, 0, true);
        _enter(stranger, 0);
        _delegate(stranger, alice, 0, false);
        _delegate(bob, alice, 0, true);
        vm.expectRevert(abi.encodeWithSelector(VisualIdentityEdition2.SeatAlreadyEntered.selector, 0));
        _enter(bob, 0);
    }

    function test_enter_revertsWithoutVIMD() public {
        vm.prank(alice);
        vimd.transfer(stranger, FUND - ENTRY_PRICE + 1);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, alice, ENTRY_PRICE - 1, ENTRY_PRICE)
        );
        _enter(alice, 0);
        assertEq(call.entryCount(), 0);
        assertEq(call.entryOfSeat(0), 0);
    }

    function test_enter_revertsWithoutAllowance() public {
        vm.prank(alice);
        vimd.approve(address(call), ENTRY_PRICE - 1);
        vm.expectRevert(
            abi.encodeWithSelector(
                IERC20Errors.ERC20InsufficientAllowance.selector, address(call), ENTRY_PRICE - 1, ENTRY_PRICE
            )
        );
        _enter(alice, 0);
    }

    function _enterLinks(string memory portraitURI, string memory packageURI) internal {
        vm.prank(alice);
        call.enter(0, bytes16(0), bytes32(0), portraitURI, bytes32(0), packageURI);
    }

    function test_enter_rejectsBadLinks() public {
        bytes memory tooLong = new bytes(201);
        for (uint256 i; i < 201; ++i) {
            tooLong[i] = "a";
        }
        string[11] memory bad = [
            "",
            string(tooLong),
            "has space.png",
            'quote"inside',
            "back\\slash",
            "tab\there",
            "newline\n",
            unicode"café",
            string(abi.encodePacked("del", bytes1(0x7f))),
            string(abi.encodePacked("nul", bytes1(0x00))),
            string(abi.encodePacked(bytes1(0x20), "lead"))
        ];
        for (uint256 i; i < bad.length; ++i) {
            vm.expectRevert(VisualIdentityEdition2.InvalidLink.selector);
            _enterLinks(bad[i], "ok");
            vm.expectRevert(VisualIdentityEdition2.InvalidLink.selector);
            _enterLinks("ok", bad[i]);
        }
        assertEq(call.entryCount(), 0);
    }

    /// @dev Reference check of the link rule: every byte in 0x21..0x7e except '"' and '\', 1..200 bytes.
    function _referenceValid(bytes memory b) internal pure returns (bool) {
        if (b.length == 0 || b.length > 200) return false;
        for (uint256 i; i < b.length; ++i) {
            bytes1 c = b[i];
            if (c < 0x21 || c > 0x7e || c == '"' || c == "\\") return false;
        }
        return true;
    }

    function testFuzz_enter_linkRuleMatchesReference(bytes calldata portrait, bytes calldata package) public {
        bool expected = _referenceValid(portrait) && _referenceValid(package);
        vm.prank(alice);
        try call.enter(0, bytes16(0), bytes32(0), string(portrait), bytes32(0), string(package)) returns (uint256 id) {
            assertTrue(expected, "accepted an invalid link");
            assertEq(call.entry(id).portraitURI, string(portrait));
            assertEq(call.entry(id).packageURI, string(package));
        } catch (bytes memory reason) {
            assertFalse(expected, "rejected a valid link");
            assertEq(bytes4(reason), VisualIdentityEdition2.InvalidLink.selector);
        }
    }

    function testFuzz_enter_acceptsEveryValidByte(uint8 c, uint8 length) public {
        c = uint8(bound(c, 0x21, 0x7e));
        vm.assume(c != 0x22 && c != 0x5c);
        length = uint8(bound(length, 1, 200));
        bytes memory link = new bytes(length);
        for (uint256 i; i < length; ++i) {
            link[i] = bytes1(c);
        }
        vm.prank(alice);
        uint256 id = call.enter(0, bytes16(0), bytes32(0), string(link), bytes32(0), string(link));
        assertEq(call.entry(id).portraitURI, string(link));
    }

    // ------------------------------------------------------------------ vote: success

    function test_vote_addsVoteSplitsVIMDAndFundsPot() public {
        uint256 e1 = _enter(alice, 0);
        _openVoting();

        uint256 burnBefore = vimd.balanceOf(BURN);
        uint256 bobBefore = vimd.balanceOf(bob);

        vm.expectEmit(address(call));
        emit VisualIdentityEdition2.Voted(2, e1, bob, 1, POT_SHARE);
        _vote(bob, 2, e1);

        assertTrue(call.seatVoted(2));
        assertEq(call.entry(e1).votes, 1);
        assertEq(call.totalVotes(), 1);
        assertEq(call.pot(), POT_SHARE);
        assertEq(vimd.balanceOf(address(call)), POT_SHARE);
        assertEq(vimd.balanceOf(BURN), burnBefore + VOTE_PRICE - POT_SHARE);
        assertEq(vimd.balanceOf(bob), bobBefore - VOTE_PRICE);
        assertEq(call.leader(), e1);
    }

    function test_vote_forOwnEntryAllowed() public {
        uint256 e1 = _enter(alice, 0);
        _openVoting();
        _vote(alice, 0, e1);
        assertEq(call.entry(e1).votes, 1);
    }

    function test_vote_walletWithSeveralSeatsHasSeveralVotes() public {
        uint256 e1 = _enter(bob, 2);
        _openVoting();
        _vote(alice, 0, e1);
        _vote(alice, 1, e1);
        assertEq(call.entry(e1).votes, 2);
        assertEq(call.totalVotes(), 2);
        assertEq(call.pot(), 2 * POT_SHARE);
    }

    function test_vote_byDelegate() public {
        uint256 e1 = _enter(alice, 0);
        _openVoting();
        _delegate(stranger, bob, 2, true);
        uint256 strangerBefore = vimd.balanceOf(stranger);
        _vote(stranger, 2, e1);
        assertTrue(call.seatVoted(2));
        assertEq(vimd.balanceOf(stranger), strangerBefore - VOTE_PRICE, "the delegate pays");
    }

    function test_vote_seatThatDidNotEnterMayVote() public {
        uint256 e1 = _enter(alice, 0);
        _openVoting();
        _vote(dave, 1999, e1);
        assertEq(call.entry(e1).votes, 1);
    }

    function test_vote_windowBoundaries() public {
        uint256 e1 = _enter(alice, 0);
        vm.warp(call.ENTRY_END());
        _vote(alice, 0, e1); // first second of voting
        vm.warp(call.VOTE_END() - 1);
        _vote(alice, 1, e1); // last second of voting
        assertEq(call.entry(e1).votes, 2);
    }

    // ------------------------------------------------------------------ vote: failure

    function test_vote_revertsBeforeEntryEnd() public {
        uint256 e1 = _enter(alice, 0);
        vm.warp(call.ENTRY_END() - 1);
        vm.expectRevert(VisualIdentityEdition2.VotingClosed.selector);
        _vote(bob, 2, e1);
    }

    function test_vote_revertsAtVoteEnd() public {
        uint256 e1 = _enter(alice, 0);
        _closeVoting();
        vm.expectRevert(VisualIdentityEdition2.VotingClosed.selector);
        _vote(bob, 2, e1);
    }

    function test_vote_revertsForNonHolder() public {
        uint256 e1 = _enter(alice, 0);
        _openVoting();
        vm.expectRevert(abi.encodeWithSelector(VisualIdentityEdition2.NotSeatHolder.selector, 2, stranger));
        _vote(stranger, 2, e1);
    }

    function test_vote_revertsForNonexistentSeat() public {
        uint256 e1 = _enter(alice, 0);
        _openVoting();
        vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721NonexistentToken.selector, 5000));
        _vote(alice, 5000, e1);
    }

    function test_vote_revertsForUnknownEntry() public {
        uint256 e1 = _enter(alice, 0);
        _openVoting();
        vm.expectRevert(abi.encodeWithSelector(VisualIdentityEdition2.UnknownEntry.selector, 0));
        _vote(bob, 2, 0);
        vm.expectRevert(abi.encodeWithSelector(VisualIdentityEdition2.UnknownEntry.selector, e1 + 1));
        _vote(bob, 2, e1 + 1);
        assertFalse(call.seatVoted(2));
    }

    function test_vote_revertsOnSecondVoteForSeat() public {
        uint256 e1 = _enter(alice, 0);
        uint256 e2 = _enter(alice, 1);
        _openVoting();
        _vote(bob, 2, e1);
        vm.expectRevert(abi.encodeWithSelector(VisualIdentityEdition2.SeatAlreadyVoted.selector, 2));
        _vote(bob, 2, e2);
        vm.expectRevert(abi.encodeWithSelector(VisualIdentityEdition2.SeatAlreadyVoted.selector, 2));
        _vote(bob, 2, e1);
    }

    function test_vote_seatSoldAfterVoteCannotVoteAgain() public {
        uint256 e1 = _enter(alice, 0);
        _openVoting();
        _vote(bob, 2, e1);
        vm.prank(bob);
        seats.transferFrom(bob, carol, 2);
        vm.expectRevert(abi.encodeWithSelector(VisualIdentityEdition2.SeatAlreadyVoted.selector, 2));
        _vote(carol, 2, e1);
    }

    function test_vote_seatRedelegatedAfterVoteCannotVoteAgain() public {
        uint256 e1 = _enter(alice, 0);
        _openVoting();
        _delegate(stranger, bob, 2, true);
        _vote(stranger, 2, e1);
        _delegate(stranger, bob, 2, false);
        _delegate(carol, bob, 2, true);
        vm.expectRevert(abi.encodeWithSelector(VisualIdentityEdition2.SeatAlreadyVoted.selector, 2));
        _vote(carol, 2, e1);
        // and the owner cannot either
        vm.expectRevert(abi.encodeWithSelector(VisualIdentityEdition2.SeatAlreadyVoted.selector, 2));
        _vote(bob, 2, e1);
    }

    function test_vote_revertsWithoutVIMDAndLeavesNoState() public {
        uint256 e1 = _enter(alice, 0);
        _openVoting();
        vm.prank(bob);
        vimd.transfer(stranger, FUND - VOTE_PRICE + 1);
        vm.expectRevert();
        _vote(bob, 2, e1);
        assertFalse(call.seatVoted(2));
        assertEq(call.pot(), 0);
        assertEq(call.totalVotes(), 0);
        assertEq(call.entry(e1).votes, 0);
    }

    // ------------------------------------------------------------------ leader

    function test_leader_revertsWithoutVotes() public {
        _enter(alice, 0);
        vm.expectRevert(VisualIdentityEdition2.NoVotes.selector);
        call.leader();
    }

    function test_leader_mostVotesThenLowerId() public {
        uint256 e1 = _enter(alice, 0);
        uint256 e2 = _enter(alice, 1);
        uint256 e3 = _enter(bob, 2);
        _openVoting();

        _vote(bob, 2, e3);
        assertEq(call.leader(), e3, "first vote leads");
        _vote(carol, 3, e2);
        assertEq(call.leader(), e2, "tie goes to the lower id");
        _vote(dave, 1999, e3);
        assertEq(call.leader(), e3, "more votes beats lower id");
        _vote(alice, 0, e1);
        assertEq(call.leader(), e3, "a lower id with fewer votes does not lead");
        _vote(alice, 1, e1);
        assertEq(call.leader(), e1, "a tie at the top goes to the lowest id");
    }

    function testFuzz_leader_matchesScan(uint8 entries, uint16[12] calldata picks) public {
        entries = uint8(bound(entries, 1, 12));
        for (uint256 i; i < entries; ++i) {
            address holder = address(uint160(0x1000 + i));
            seats.mint(holder, 10 + i);
            vimd.mint(holder, ENTRY_PRICE);
            vm.prank(holder);
            vimd.approve(address(call), type(uint256).max);
            _enter(holder, 10 + i);
        }
        _openVoting();
        for (uint256 i; i < picks.length; ++i) {
            address voter = address(uint160(0x2000 + i));
            seats.mint(voter, 100 + i);
            vimd.mint(voter, VOTE_PRICE);
            vm.prank(voter);
            vimd.approve(address(call), type(uint256).max);
            _vote(voter, 100 + i, 1 + (picks[i] % entries));
        }
        uint256 best;
        uint256 bestVotes;
        for (uint256 id = 1; id <= entries; ++id) {
            uint256 v = call.entry(id).votes;
            if (v > bestVotes) {
                bestVotes = v;
                best = id;
            }
        }
        assertEq(call.leader(), best);
        assertEq(call.totalVotes(), picks.length);
        assertEq(call.pot(), picks.length * POT_SHARE);
    }

    // ------------------------------------------------------------------ claimPrize

    function test_claimPrize_paysLeadingEntrantOnce() public {
        uint256 e1 = _enter(alice, 0);
        uint256 e2 = _enter(bob, 2);
        _openVoting();
        _vote(alice, 0, e2);
        _vote(alice, 1, e2);
        _vote(carol, 3, e1);
        _closeVoting();

        uint256 bobBefore = vimd.balanceOf(bob);
        vm.expectEmit(address(call));
        emit VisualIdentityEdition2.PrizeClaimed(e2, bob, 3 * POT_SHARE);
        vm.prank(stranger); // anyone
        call.claimPrize();

        assertEq(vimd.balanceOf(bob), bobBefore + 3 * POT_SHARE);
        assertEq(vimd.balanceOf(address(call)), 0);
        assertEq(call.pot(), 0);
        assertTrue(call.prizeClaimed());
        assertEq(call.leader(), e2, "leader stays readable after the claim");

        vm.expectRevert(VisualIdentityEdition2.PrizeAlreadyClaimed.selector);
        call.claimPrize();
    }

    function test_claimPrize_paysStoredEntrantNotCurrentNFTHolder() public {
        uint256 e1 = _enter(alice, 0);
        vm.prank(alice);
        call.transferFrom(alice, stranger, e1);
        _openVoting();
        _vote(bob, 2, e1);
        _closeVoting();
        uint256 aliceBefore = vimd.balanceOf(alice);
        uint256 strangerBefore = vimd.balanceOf(stranger);
        call.claimPrize();
        assertEq(vimd.balanceOf(alice), aliceBefore + POT_SHARE);
        assertEq(vimd.balanceOf(stranger), strangerBefore);
    }

    function test_claimPrize_revertsBeforeVoteEnd() public {
        uint256 e1 = _enter(alice, 0);
        _openVoting();
        _vote(bob, 2, e1);
        vm.warp(call.VOTE_END() - 1);
        vm.expectRevert(VisualIdentityEdition2.VotingNotEnded.selector);
        call.claimPrize();
    }

    function test_claimPrize_revertsWithoutVotes() public {
        _enter(alice, 0);
        _closeVoting();
        vm.expectRevert(VisualIdentityEdition2.NoVotes.selector);
        call.claimPrize();
        assertEq(call.pot(), 0);
        assertFalse(call.prizeClaimed());
    }

    function test_claimPrize_revertsWithoutEntriesOrVotes() public {
        _closeVoting();
        vm.expectRevert(VisualIdentityEdition2.NoVotes.selector);
        call.claimPrize();
    }

    function test_claimPrize_donationsAreNotPartOfPotAndStay() public {
        uint256 e1 = _enter(alice, 0);
        vm.prank(stranger);
        vimd.transfer(address(call), 777e18);
        _openVoting();
        _vote(bob, 2, e1);
        assertEq(call.pot(), POT_SHARE);
        _closeVoting();
        call.claimPrize();
        assertEq(vimd.balanceOf(address(call)), 777e18, "donation stays in the contract");
        assertEq(call.pot(), 0);
    }

    function test_noOtherWayForVIMDToLeave() public {
        uint256 e1 = _enter(alice, 0);
        _openVoting();
        _vote(bob, 2, e1);
        bytes[5] memory calls = [
            abi.encodeWithSignature("withdraw()"),
            abi.encodeWithSignature("sweep(address)", stranger),
            abi.encodeWithSignature("rescue(address,uint256)", VIMD_ADDR, POT_SHARE),
            abi.encodeWithSignature("transferVIMD(address,uint256)", stranger, POT_SHARE),
            abi.encodeWithSignature("execute(address,bytes)", VIMD_ADDR, "")
        ];
        for (uint256 i; i < calls.length; ++i) {
            vm.prank(stranger);
            (bool ok,) = address(call).call(calls[i]);
            assertFalse(ok);
        }
        assertEq(vimd.balanceOf(address(call)), POT_SHARE);
        assertEq(address(call).balance, 0);
        (bool sent,) = address(call).call{value: 1 ether}("");
        assertFalse(sent, "no receive/fallback");
    }

    // ------------------------------------------------------------------ conservation

    function testFuzz_conservation_contractHoldsExactlyPotPlusDonations(uint8 voters, uint96 donation) public {
        voters = uint8(bound(voters, 0, 20));
        uint256 e1 = _enter(alice, 0);
        uint256 e2 = _enter(bob, 2);
        vimd.mint(stranger, donation);
        vm.prank(stranger);
        vimd.transfer(address(call), donation);
        _openVoting();
        uint256 burnBefore = vimd.balanceOf(BURN);
        for (uint256 i; i < voters; ++i) {
            address voter = address(uint160(0x3000 + i));
            seats.mint(voter, 500 + i);
            vimd.mint(voter, VOTE_PRICE);
            vm.prank(voter);
            vimd.approve(address(call), VOTE_PRICE);
            _vote(voter, 500 + i, i % 2 == 0 ? e1 : e2);
            assertEq(vimd.balanceOf(address(call)), call.pot() + donation);
        }
        assertEq(call.pot(), uint256(voters) * POT_SHARE);
        assertEq(vimd.balanceOf(BURN) - burnBefore, uint256(voters) * (VOTE_PRICE - POT_SHARE));
        _closeVoting();
        if (voters == 0) {
            vm.expectRevert(VisualIdentityEdition2.NoVotes.selector);
            call.claimPrize();
            assertEq(vimd.balanceOf(address(call)), donation);
            return;
        }
        uint256 winner = call.leader();
        address entrant = call.entry(winner).entrant;
        uint256 before = vimd.balanceOf(entrant);
        call.claimPrize();
        assertEq(vimd.balanceOf(entrant) - before, uint256(voters) * POT_SHARE);
        assertEq(vimd.balanceOf(address(call)), donation);
        assertEq(call.pot(), 0);
    }

    // ------------------------------------------------------------------ reentrancy

    function test_reentrancy_throughMintReceiverIsBlocked() public {
        ReentrantReceiver attacker = new ReentrantReceiver(call, 2);
        vm.prank(bob);
        seats.transferFrom(bob, address(attacker), 2);
        vimd.mint(address(attacker), 2 * ENTRY_PRICE);
        vm.prank(address(attacker));
        vimd.approve(address(call), type(uint256).max);

        uint256 id = attacker.enter();
        assertEq(id, 1);
        assertEq(attacker.attempts(), 1, "callback ran");
        assertEq(bytes4(attacker.lastRevert()), ReentrancyGuard.ReentrancyGuardReentrantCall.selector);
        assertEq(call.entryCount(), 1);
        assertEq(call.balanceOf(address(attacker)), 1);
        assertEq(vimd.balanceOf(address(attacker)), ENTRY_PRICE, "paid exactly once");
    }

    function _armReentrantVIMD() internal returns (ReentrantVIMD token) {
        vm.etch(VIMD_ADDR, type(ReentrantVIMD).runtimeCode);
        token = ReentrantVIMD(VIMD_ADDR);
        address[4] memory users = [alice, bob, carol, stranger];
        for (uint256 i; i < users.length; ++i) {
            token.mint(users[i], FUND);
            vm.prank(users[i]);
            token.approve(address(call), type(uint256).max);
        }
    }

    function test_reentrancy_throughVIMDOnEnterIsBlocked() public {
        ReentrantVIMD token = _armReentrantVIMD();
        token.arm(
            call,
            abi.encodeCall(
                VisualIdentityEdition2.enter, (0, bytes16(0), bytes32(0), "ipfs://x", bytes32(0), "ipfs://y")
            )
        );
        _enter(alice, 1);
        assertEq(token.attempts(), 1);
        assertEq(bytes4(token.lastRevert()), ReentrancyGuard.ReentrancyGuardReentrantCall.selector);
        assertEq(call.entryCount(), 1);
    }

    function test_reentrancy_throughVIMDOnVoteIsBlocked() public {
        ReentrantVIMD token = _armReentrantVIMD();
        uint256 e1 = _enter(alice, 0);
        _openVoting();
        token.arm(call, abi.encodeCall(VisualIdentityEdition2.vote, (3, e1)));
        _vote(bob, 2, e1);
        assertEq(token.attempts(), 1);
        assertEq(bytes4(token.lastRevert()), ReentrancyGuard.ReentrancyGuardReentrantCall.selector);
        assertEq(call.totalVotes(), 1);
        assertEq(call.pot(), POT_SHARE);
        assertEq(token.balanceOf(address(call)), POT_SHARE);
    }

    function test_reentrancy_throughVIMDOnClaimIsBlocked() public {
        ReentrantVIMD token = _armReentrantVIMD();
        uint256 e1 = _enter(alice, 0);
        _openVoting();
        _vote(bob, 2, e1);
        _closeVoting();
        token.arm(call, abi.encodeCall(VisualIdentityEdition2.claimPrize, ()));
        uint256 before = token.balanceOf(alice);
        call.claimPrize();
        assertEq(token.attempts(), 1);
        // The guard rejects the re-entry; even without it, prizeClaimed is already set before the transfer.
        assertEq(bytes4(token.lastRevert()), ReentrancyGuard.ReentrancyGuardReentrantCall.selector);
        assertEq(token.balanceOf(alice) - before, POT_SHARE, "paid exactly pot, once");
        assertEq(token.balanceOf(address(call)), 0);
    }

    // ------------------------------------------------------------------ tokenURI

    function test_tokenURI_isOnChainJSON() public {
        vm.prank(alice);
        uint256 id = call.enter(
            1, bytes16(0), bytes32(0), "ipfs://bafy/portrait.png", bytes32(0), "https://example.com/brand.zip?x=1&y=<2>"
        );
        _openVoting();
        _vote(bob, 2, id);
        _vote(carol, 3, id);

        string memory expectedJson = string.concat(
            '{"name":"VisualIdentity.md Edition 2: Agent 1",',
            '"description":"Portrait of IMD agent 1, drawn by a fellow agent of the swarm, ',
            "with its owner's brand package for IMD.\",",
            '"image":"ipfs://bafy/portrait.png",',
            '"external_url":"https://example.com/brand.zip?x=1&y=<2>",',
            '"attributes":[{"trait_type":"Edition","value":"2"},',
            '{"trait_type":"Agent","value":"1"},',
            '{"trait_type":"Votes","value":"2"}]}'
        );
        string memory expected = string.concat("data:application/json;base64,", Base64.encode(bytes(expectedJson)));
        assertEq(call.tokenURI(id), expected);
    }

    function test_tokenURI_votesUpdateLive() public {
        uint256 id = _enter(dave, 1999);
        string memory before = call.tokenURI(id);
        _openVoting();
        _vote(alice, 0, id);
        assertNotEq(call.tokenURI(id), before);
        string memory expectedJson = string.concat(
            '{"name":"VisualIdentity.md Edition 2: Agent 1999",',
            '"description":"Portrait of IMD agent 1999, drawn by a fellow agent of the swarm, ',
            "with its owner's brand package for IMD.\",",
            '"image":"ipfs://portrait/1999",',
            '"external_url":"https://example.com/package/1999.zip",',
            '"attributes":[{"trait_type":"Edition","value":"2"},',
            '{"trait_type":"Agent","value":"1999"},',
            '{"trait_type":"Votes","value":"1"}]}'
        );
        assertEq(call.tokenURI(id), string.concat("data:application/json;base64,", Base64.encode(bytes(expectedJson))));
    }

    function test_tokenURI_revertsForUnknownToken() public {
        vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721NonexistentToken.selector, 1));
        call.tokenURI(1);
    }

    // ------------------------------------------------------------------ views

    function test_views_defaults() public view {
        assertEq(call.entryOfSeat(0), 0);
        assertFalse(call.seatVoted(0));
        VisualIdentityEdition2.Entry memory e = call.entry(0);
        assertEq(e.entrant, address(0));
        assertEq(bytes(e.portraitURI).length, 0);
        e = call.entry(99);
        assertEq(e.seatId, 0);
    }
}
