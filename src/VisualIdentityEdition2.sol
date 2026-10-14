// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Base64} from "@openzeppelin/contracts/utils/Base64.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";

/// @notice delegate.xyz DelegateRegistry v2, the one read this contract makes of it.
interface IDelegateRegistry {
    function checkDelegateForERC721(address to, address from, address contract_, uint256 tokenId, bytes32 rights)
        external
        view
        returns (bool);
}

/// @title VisualIdentity.md Edition 2
/// @notice Open call for identity.md agent seats: each seat may enter one brand package together with a
///         portrait of its agent, then each seat may cast one vote. Entering burns VIMD; voting burns half
///         of its price and pools the other half as the prize, paid once to the entrant of the leading entry.
///         One ERC-721 is minted per entry. There is no owner, admin, role, setting, pause or upgrade.
contract VisualIdentityEdition2 is ERC721, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // ------------------------------------------------------------------ outside contracts (Ethereum mainnet)

    /// @notice VIMD, launch 1645's token, a plain ERC-20 with 18 decimals.
    IERC20 public constant VIMD = IERC20(0x931fD96a22BcA8E1008D18ed827D5C042932BE17);
    /// @notice identity.md seats, ERC-721 ids 0 to 1999.
    IERC721 public constant SEATS = IERC721(0x0000eC93127BAA929E58E97dd0095A2BFb38ec1D);
    /// @notice delegate.xyz DelegateRegistry v2.
    IDelegateRegistry public constant DELEGATE_REGISTRY = IDelegateRegistry(0x00000000000000447e69651d841bD8D104Bed493);
    /// @notice VIMD is burned by transferring it here.
    address public constant BURN_ADDRESS = 0x000000000000000000000000000000000000dEaD;

    // ------------------------------------------------------------------ prices and times

    /// @notice VIMD burned by an entry.
    uint256 public constant ENTRY_PRICE = 25_000e18;
    /// @notice VIMD a vote costs in total.
    uint256 public constant VOTE_PRICE = 50_000e18;
    /// @notice The part of VOTE_PRICE kept by the contract and added to the pot; the rest is burned.
    uint256 public constant VOTE_POT_SHARE = 25_000e18;

    /// @notice Entries close at this time (exclusive); voting opens at it (inclusive).
    uint256 public immutable ENTRY_END;
    /// @notice Voting closes at this time (exclusive); the prize may be claimed from it (inclusive).
    uint256 public immutable VOTE_END;

    // ------------------------------------------------------------------ storage

    struct Entry {
        uint256 seatId;
        address entrant;
        bytes16 portraitJob;
        bytes32 portraitHash;
        string portraitURI;
        bytes32 packageHash;
        string packageURI;
        uint256 votes;
    }

    /// @notice Number of entries; entry ids and NFT ids run from 1 to entryCount.
    uint256 public entryCount;
    /// @notice Entry id a seat entered with, 0 if it has not entered.
    mapping(uint256 seatId => uint256 entryId) public entryOfSeat;
    /// @notice Whether a seat has voted.
    mapping(uint256 seatId => bool) public seatVoted;
    /// @notice VIMD held for the winner: VOTE_POT_SHARE per vote, 0 once claimed.
    uint256 public pot;
    /// @notice Votes cast in total.
    uint256 public totalVotes;
    /// @notice Whether the prize has been paid.
    bool public prizeClaimed;

    mapping(uint256 entryId => Entry) private _entries;
    /// @dev Lowest entry id among those with the most votes; 0 until the first vote.
    uint256 private _leaderId;

    // ------------------------------------------------------------------ events and errors

    event Entered(
        uint256 indexed entryId,
        uint256 indexed seatId,
        address indexed entrant,
        bytes16 portraitJob,
        bytes32 portraitHash,
        string portraitURI,
        bytes32 packageHash,
        string packageURI
    );
    event Voted(uint256 indexed seatId, uint256 indexed entryId, address indexed voter, uint256 votes, uint256 pot);
    event PrizeClaimed(uint256 indexed entryId, address indexed entrant, uint256 amount);

    error NotSeatHolder(uint256 seatId, address caller);
    error EntryClosed();
    error VotingClosed();
    error VotingNotEnded();
    error SeatAlreadyEntered(uint256 seatId);
    error SeatAlreadyVoted(uint256 seatId);
    error InvalidLink();
    error UnknownEntry(uint256 entryId);
    error NoVotes();
    error PrizeAlreadyClaimed();

    constructor() ERC721("VisualIdentity.md Edition 2", "VIMD2") {
        ENTRY_END = block.timestamp + 4 days;
        VOTE_END = block.timestamp + 7 days;
    }

    // ------------------------------------------------------------------ actions

    /// @notice Enter the seat's brand package and agent portrait. Mints NFT `entryId` to the caller and
    ///         burns ENTRY_PRICE VIMD from the caller. The job id, hashes and links are the entrant's claim;
    ///         the website checks them against IMD's public job record.
    function enter(
        uint256 seatId,
        bytes16 portraitJob,
        bytes32 portraitHash,
        string calldata portraitURI,
        bytes32 packageHash,
        string calldata packageURI
    ) external nonReentrant returns (uint256 entryId) {
        if (block.timestamp >= ENTRY_END) revert EntryClosed();
        _requireSeatHolder(seatId);
        if (entryOfSeat[seatId] != 0) revert SeatAlreadyEntered(seatId);
        if (!_isValidLink(portraitURI) || !_isValidLink(packageURI)) revert InvalidLink();

        entryId = ++entryCount;
        entryOfSeat[seatId] = entryId;
        Entry storage e = _entries[entryId];
        e.seatId = seatId;
        e.entrant = msg.sender;
        e.portraitJob = portraitJob;
        e.portraitHash = portraitHash;
        e.portraitURI = portraitURI;
        e.packageHash = packageHash;
        e.packageURI = packageURI;
        emit Entered(entryId, seatId, msg.sender, portraitJob, portraitHash, portraitURI, packageHash, packageURI);

        _safeMint(msg.sender, entryId);
        VIMD.safeTransferFrom(msg.sender, BURN_ADDRESS, ENTRY_PRICE);
    }

    /// @notice Cast the seat's one vote for `entryId`. Costs VOTE_PRICE VIMD from the caller: VOTE_POT_SHARE
    ///         is kept for the winner, the rest is burned.
    function vote(uint256 seatId, uint256 entryId) external nonReentrant {
        if (block.timestamp < ENTRY_END || block.timestamp >= VOTE_END) revert VotingClosed();
        _requireSeatHolder(seatId);
        if (seatVoted[seatId]) revert SeatAlreadyVoted(seatId);
        if (entryId == 0 || entryId > entryCount) revert UnknownEntry(entryId);

        seatVoted[seatId] = true;
        uint256 votes = ++_entries[entryId].votes;
        ++totalVotes;
        pot += VOTE_POT_SHARE;
        uint256 leaderId = _leaderId;
        if (
            leaderId == 0 || votes > _entries[leaderId].votes
                || (votes == _entries[leaderId].votes && entryId < leaderId)
        ) {
            _leaderId = entryId;
        }
        emit Voted(seatId, entryId, msg.sender, votes, pot);

        VIMD.safeTransferFrom(msg.sender, BURN_ADDRESS, VOTE_PRICE - VOTE_POT_SHARE);
        VIMD.safeTransferFrom(msg.sender, address(this), VOTE_POT_SHARE);
    }

    /// @notice Pay the whole pot to the entrant of the leading entry. Anyone may call it, once, from VOTE_END.
    function claimPrize() external nonReentrant {
        if (block.timestamp < VOTE_END) revert VotingNotEnded();
        if (prizeClaimed) revert PrizeAlreadyClaimed();
        uint256 entryId = leader();
        address entrant = _entries[entryId].entrant;
        uint256 amount = pot;

        prizeClaimed = true;
        pot = 0;
        emit PrizeClaimed(entryId, entrant, amount);

        VIMD.safeTransfer(entrant, amount);
    }

    // ------------------------------------------------------------------ views

    /// @notice The entry with the most votes; on a tie, the one with the lower id. Reverts before the first vote.
    function leader() public view returns (uint256 entryId) {
        entryId = _leaderId;
        if (entryId == 0) revert NoVotes();
    }

    /// @notice Every stored field of entry `entryId`. All zero for an id that does not exist.
    function entry(uint256 entryId) external view returns (Entry memory) {
        return _entries[entryId];
    }

    /// @inheritdoc ERC721
    function tokenURI(uint256 tokenId) public view override returns (string memory) {
        _requireOwned(tokenId);
        Entry storage e = _entries[tokenId];
        string memory seat = Strings.toString(e.seatId);
        bytes memory json = bytes.concat(
            '{"name":"VisualIdentity.md Edition 2: Agent ',
            bytes(seat),
            '","description":"Portrait of IMD agent ',
            bytes(seat),
            ", drawn by a fellow agent of the swarm, with its owner's brand package for IMD.",
            '","image":"',
            bytes(e.portraitURI),
            '","external_url":"',
            bytes(e.packageURI),
            '","attributes":[{"trait_type":"Edition","value":"2"},{"trait_type":"Agent","value":"',
            bytes(seat),
            '"},{"trait_type":"Votes","value":"',
            bytes(Strings.toString(e.votes)),
            '"}]}'
        );
        return string.concat("data:application/json;base64,", Base64.encode(json));
    }

    // ------------------------------------------------------------------ internals

    /// @dev msg.sender must own the seat or hold a live delegate.xyz delegation for it from its owner.
    ///      SEATS.ownerOf reverts for a seat id that does not exist.
    function _requireSeatHolder(uint256 seatId) internal view {
        address owner = SEATS.ownerOf(seatId);
        if (
            msg.sender != owner
                && !DELEGATE_REGISTRY.checkDelegateForERC721(msg.sender, owner, address(SEATS), seatId, bytes32(0))
        ) revert NotSeatHolder(seatId, msg.sender);
    }

    /// @dev 1 to 200 bytes, each printable ASCII (0x21 to 0x7e), no double quote (0x22) and no backslash (0x5c),
    ///      so the link can be placed in the tokenURI JSON unescaped.
    function _isValidLink(string calldata link) internal pure returns (bool) {
        bytes calldata b = bytes(link);
        if (b.length == 0 || b.length > 200) return false;
        for (uint256 i; i < b.length; ++i) {
            uint8 c = uint8(b[i]);
            if (c < 0x21 || c > 0x7e || c == 0x22 || c == 0x5c) return false;
        }
        return true;
    }
}
