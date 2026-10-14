// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC721Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {Base64} from "@openzeppelin/contracts/utils/Base64.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";

import {VisualIdentityEdition2} from "../src/VisualIdentityEdition2.sol";
import {MockVIMD} from "./mocks/MockVIMD.sol";
import {MockSeats} from "./mocks/MockSeats.sol";
import {MockDelegateRegistry} from "./mocks/MockDelegateRegistry.sol";

/// @notice A seat holder that is a contract without onERC721Received: _safeMint must refuse it.
contract NoReceiver {
    function enter(VisualIdentityEdition2 call, uint256 seatId) external returns (uint256) {
        return call.enter(seatId, bytes16(0), bytes32(0), "ipfs://p", bytes32(0), "ipfs://k");
    }
}

/// @notice Edges the main suite leaves open: delegations that go stale when a seat is sold, the owner acting
///         after its delegate did, contract callers that cannot receive the NFT, the prize following the stored
///         entrant and not the seat, and the tokenURI document checked by a real JSON parser for every valid link.
contract VisualIdentityEdition2EdgesTest is Test {
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

    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address carol = makeAddr("carol");
    address delegatee = makeAddr("delegatee");

    function setUp() public {
        vm.etch(VIMD_ADDR, type(MockVIMD).runtimeCode);
        vm.etch(SEATS_ADDR, type(MockSeats).runtimeCode);
        vm.etch(REGISTRY_ADDR, type(MockDelegateRegistry).runtimeCode);
        vm.warp(1_800_000_000);
        call = new VisualIdentityEdition2();

        seats.mint(alice, 0);
        seats.mint(alice, 1);
        seats.mint(bob, 2);
        seats.mint(carol, 3);
        address[4] memory users = [alice, bob, carol, delegatee];
        for (uint256 i; i < users.length; ++i) {
            vimd.mint(users[i], 1_000_000e18);
            vm.prank(users[i]);
            vimd.approve(address(call), type(uint256).max);
        }
    }

    function _enter(address who, uint256 seatId) internal returns (uint256 id) {
        vm.prank(who);
        id = call.enter(seatId, bytes16(0), bytes32(0), "ipfs://portrait", bytes32(0), "ipfs://package");
    }

    function _delegate(address to, address from, uint256 seatId, bool on) internal {
        registry.setDelegate(to, from, SEATS_ADDR, seatId, bytes32(0), on);
    }

    // ------------------------------------------------------------------ delegation goes stale with the seat

    function test_enter_delegationFromPreviousOwnerStopsCountingAfterSale() public {
        _delegate(delegatee, alice, 0, true);
        vm.prank(alice);
        seats.transferFrom(alice, bob, 0);
        // The registry still holds alice -> delegatee for seat 0, but alice no longer owns it.
        assertTrue(registry.checkDelegateForERC721(delegatee, alice, SEATS_ADDR, 0, bytes32(0)));
        vm.expectRevert(abi.encodeWithSelector(VisualIdentityEdition2.NotSeatHolder.selector, 0, delegatee));
        _enter(delegatee, 0);
        // The old owner cannot act for it either.
        vm.expectRevert(abi.encodeWithSelector(VisualIdentityEdition2.NotSeatHolder.selector, 0, alice));
        _enter(alice, 0);
        // The new owner can.
        assertEq(_enter(bob, 0), 1);
    }

    function test_vote_delegationFromPreviousOwnerStopsCountingAfterSale() public {
        uint256 e1 = _enter(alice, 1);
        _delegate(delegatee, bob, 2, true);
        vm.prank(bob);
        seats.transferFrom(bob, carol, 2);
        vm.warp(call.ENTRY_END());
        vm.expectRevert(abi.encodeWithSelector(VisualIdentityEdition2.NotSeatHolder.selector, 2, delegatee));
        vm.prank(delegatee);
        call.vote(2, e1);
        vm.expectRevert(abi.encodeWithSelector(VisualIdentityEdition2.NotSeatHolder.selector, 2, bob));
        vm.prank(bob);
        call.vote(2, e1);
        vm.prank(carol);
        call.vote(2, e1);
        assertEq(call.entry(e1).votes, 1);
    }

    function test_ownerCannotEnterOrVoteAfterItsDelegateDid() public {
        _delegate(delegatee, alice, 0, true);
        uint256 e1 = _enter(delegatee, 0);
        vm.expectRevert(abi.encodeWithSelector(VisualIdentityEdition2.SeatAlreadyEntered.selector, 0));
        _enter(alice, 0);

        vm.warp(call.ENTRY_END());
        vm.prank(delegatee);
        call.vote(0, e1);
        vm.expectRevert(abi.encodeWithSelector(VisualIdentityEdition2.SeatAlreadyVoted.selector, 0));
        vm.prank(alice);
        call.vote(0, e1);
    }

    function test_delegateOfOneSeatMayActForEachSeatDelegatedSeparately() public {
        _delegate(delegatee, alice, 0, true);
        _delegate(delegatee, alice, 1, true);
        uint256 e1 = _enter(delegatee, 0);
        uint256 e2 = _enter(delegatee, 1);
        assertEq(call.balanceOf(delegatee), 2);
        vm.warp(call.ENTRY_END());
        vm.startPrank(delegatee);
        call.vote(0, e2);
        call.vote(1, e1);
        vm.stopPrank();
        assertEq(call.totalVotes(), 2);
        assertEq(call.leader(), e1, "tie goes to the lower id");
    }

    // ------------------------------------------------------------------ contract callers

    function test_enter_contractWithoutReceiverIsRefusedAndLeavesNoState() public {
        NoReceiver holder = new NoReceiver();
        vm.prank(alice);
        seats.transferFrom(alice, address(holder), 0);
        vimd.mint(address(holder), ENTRY_PRICE);
        vm.prank(address(holder));
        vimd.approve(address(call), ENTRY_PRICE);

        vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721InvalidReceiver.selector, address(holder)));
        holder.enter(call, 0);
        assertEq(call.entryCount(), 0);
        assertEq(call.entryOfSeat(0), 0, "the seat is not used up by a failed entry");
        assertEq(vimd.balanceOf(address(holder)), ENTRY_PRICE, "nothing was charged");
    }

    // ------------------------------------------------------------------ prize follows the stored entrant

    function test_claimPrize_paysEntrantEvenAfterSeatAndNFTAreSold() public {
        uint256 e1 = _enter(alice, 0);
        vm.startPrank(alice);
        seats.transferFrom(alice, carol, 0);
        call.transferFrom(alice, bob, e1);
        vm.stopPrank();
        vm.warp(call.ENTRY_END());
        vm.prank(bob);
        call.vote(2, e1);
        vm.warp(call.VOTE_END());
        uint256 aliceBefore = vimd.balanceOf(alice);
        uint256 bobBefore = vimd.balanceOf(bob);
        uint256 carolBefore = vimd.balanceOf(carol);
        call.claimPrize();
        assertEq(vimd.balanceOf(alice), aliceBefore + POT_SHARE, "the entrant is paid");
        assertEq(vimd.balanceOf(bob), bobBefore, "not the NFT holder");
        assertEq(vimd.balanceOf(carol), carolBefore, "not the seat holder");
    }

    function test_claimPrize_atVoteEndExactlyAndLateVoteRefused() public {
        uint256 e1 = _enter(alice, 0);
        vm.warp(call.ENTRY_END());
        vm.prank(bob);
        call.vote(2, e1);
        vm.warp(call.VOTE_END());
        vm.expectRevert(VisualIdentityEdition2.VotingClosed.selector);
        vm.prank(carol);
        call.vote(3, e1);
        call.claimPrize();
        assertTrue(call.prizeClaimed());
        assertEq(vimd.balanceOf(address(call)), 0);
    }

    function test_claimPrize_muchLaterStillWorksOnce() public {
        uint256 e1 = _enter(alice, 0);
        vm.warp(call.ENTRY_END());
        vm.prank(bob);
        call.vote(2, e1);
        vm.warp(call.VOTE_END() + 365 days);
        call.claimPrize();
        vm.expectRevert(VisualIdentityEdition2.PrizeAlreadyClaimed.selector);
        call.claimPrize();
    }

    // ------------------------------------------------------------------ tokenURI through a real JSON parser

    /// @dev Decode the data URI by re-encoding the expected JSON: tokenURI must equal the base64 of a document
    ///      that a JSON parser accepts and whose fields hold the links unchanged.
    function _expectedJson(uint256 seatId, string memory portrait, string memory pkg, uint256 votes)
        internal
        pure
        returns (string memory)
    {
        string memory seat = Strings.toString(seatId);
        return string.concat(
            '{"name":"VisualIdentity.md Edition 2: Agent ',
            seat,
            '","description":"Portrait of IMD agent ',
            seat,
            ", drawn by a fellow agent of the swarm, with its owner's brand package for IMD.",
            '","image":"',
            portrait,
            '","external_url":"',
            pkg,
            '","attributes":[{"trait_type":"Edition","value":"2"},{"trait_type":"Agent","value":"',
            seat,
            '"},{"trait_type":"Votes","value":"',
            Strings.toString(votes),
            '"}]}'
        );
    }

    function _assertTokenURIParses(uint256 id, uint256 seatId, string memory portrait, string memory pkg, uint256 votes)
        internal
        view
    {
        string memory json = _expectedJson(seatId, portrait, pkg, votes);
        assertEq(call.tokenURI(id), string.concat("data:application/json;base64,", Base64.encode(bytes(json))));
        // A real parser accepts the document and the links come back byte for byte.
        assertEq(vm.parseJsonString(json, ".image"), portrait);
        assertEq(vm.parseJsonString(json, ".external_url"), pkg);
        assertEq(
            vm.parseJsonString(json, ".name"),
            string.concat("VisualIdentity.md Edition 2: Agent ", Strings.toString(seatId))
        );
        assertEq(vm.parseJsonString(json, ".attributes[1].value"), Strings.toString(seatId));
        assertEq(vm.parseJsonString(json, ".attributes[2].value"), Strings.toString(votes));
        assertEq(vm.parseJsonString(json, ".attributes[0].value"), "2");
    }

    function test_tokenURI_jsonSurvivesEveryPrintableCharacterAllowedInLinks() public {
        // Every allowed byte once, in order: 0x21..0x7e minus '"' and '\'. 92 bytes.
        bytes memory all = new bytes(92);
        uint256 n;
        for (uint256 c = 0x21; c <= 0x7e; ++c) {
            if (c == 0x22 || c == 0x5c) continue;
            all[n++] = bytes1(uint8(c));
        }
        string memory link = string(all);
        vm.prank(alice);
        uint256 id = call.enter(1, bytes16(0), bytes32(0), link, bytes32(0), link);
        _assertTokenURIParses(id, 1, link, link, 0);
    }

    function test_tokenURI_injectionShapedLinksAreInertWithoutQuoteOrBackslash() public {
        // Would close the string or add keys if a quote or backslash were allowed; without them it is just text.
        string memory portrait = "ipfs://x,image:evil,attributes:[],}{";
        string memory pkg = "https://e.com/?a=1&b='2'&c=</script>&d=%22";
        vm.prank(alice);
        uint256 id = call.enter(0, bytes16(0), bytes32(0), portrait, bytes32(0), pkg);
        _assertTokenURIParses(id, 0, portrait, pkg, 0);
        vm.warp(call.ENTRY_END());
        vm.prank(bob);
        call.vote(2, id);
        _assertTokenURIParses(id, 0, portrait, pkg, 1);
    }

    /// forge-config: default.fuzz.runs = 512
    function testFuzz_tokenURI_anyValidLinkRoundTripsThroughJsonParser(
        bytes calldata rawPortrait,
        bytes calldata rawPkg
    ) public {
        string memory portrait = _toValidLink(rawPortrait);
        string memory pkg = _toValidLink(rawPkg);
        vm.prank(alice);
        uint256 id = call.enter(1, bytes16(0), bytes32(0), portrait, bytes32(0), pkg);
        _assertTokenURIParses(id, 1, portrait, pkg, 0);
    }

    /// @dev Maps arbitrary bytes onto the allowed alphabet (1..200 bytes), so no input is discarded.
    function _toValidLink(bytes calldata raw) internal pure returns (string memory) {
        uint256 len = bound(raw.length, 1, 200);
        bytes memory out = new bytes(len);
        for (uint256 i; i < len; ++i) {
            uint8 c = i < raw.length ? uint8(raw[i]) : uint8(i);
            // 92 allowed symbols: 0x21..0x7e without 0x22 and 0x5c
            uint8 k = c % 92;
            uint8 ch = 0x21 + k;
            if (ch >= 0x22) ch += 1; // skip '"'
            if (ch >= 0x5c) ch += 1; // skip '\'
            out[i] = bytes1(ch);
        }
        return string(out);
    }

    function test_toValidLinkCoversAlphabetExactly() public pure {
        // Sanity check of the fuzz mapper: the 92 residues map onto exactly the allowed bytes, none forbidden.
        bytes memory seen = new bytes(128);
        for (uint8 k; k < 92; ++k) {
            uint8 ch = 0x21 + k;
            if (ch >= 0x22) ch += 1;
            if (ch >= 0x5c) ch += 1;
            assertTrue(ch >= 0x21 && ch <= 0x7e && ch != 0x22 && ch != 0x5c);
            assertEq(uint8(seen[ch]), 0, "duplicate");
            seen[ch] = bytes1(uint8(1));
        }
    }
}
