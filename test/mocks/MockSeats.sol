// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";

/// @notice ERC-721 standing in for the identity.md seats. ownerOf reverts for an id that was never minted,
///         as the real seats do for an id that does not exist.
contract MockSeats is ERC721 {
    constructor() ERC721("", "") {}

    function mint(address to, uint256 seatId) external {
        _mint(to, seatId);
    }
}
