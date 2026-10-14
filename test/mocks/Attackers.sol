// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import {VisualIdentityEdition2} from "../../src/VisualIdentityEdition2.sol";

/// @notice Seat holder that re-enters the call through the ERC-721 receiver callback of its own mint.
contract ReentrantReceiver is IERC721Receiver {
    VisualIdentityEdition2 public immutable call;
    uint256 public immutable seatId;
    uint256 public attempts;
    bytes public lastRevert;

    constructor(VisualIdentityEdition2 call_, uint256 seatId_) {
        call = call_;
        seatId = seatId_;
    }

    function enter() external returns (uint256) {
        return call.enter(seatId, bytes16(0), bytes32(0), "ipfs://portrait", bytes32(0), "ipfs://package");
    }

    function onERC721Received(address, address, uint256, bytes calldata) external override returns (bytes4) {
        ++attempts;
        // Re-entering enter() (for the same or another seat) must fail; the seat's entry is already recorded.
        try call.enter(seatId, bytes16(0), bytes32(0), "ipfs://again", bytes32(0), "ipfs://again") {
            revert("re-entered");
        } catch (bytes memory reason) {
            lastRevert = reason;
        }
        return IERC721Receiver.onERC721Received.selector;
    }
}

/// @notice An ERC-20 that calls back into the contract from transferFrom and transfer. Etched at VIMD's address
///         to stand in for a token with hooks; the real VIMD is a plain ERC-20 and has none.
contract ReentrantVIMD is ERC20 {
    VisualIdentityEdition2 public target;
    bytes public reenterCall;
    bytes public lastRevert;
    uint256 public attempts;

    constructor() ERC20("", "") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function arm(VisualIdentityEdition2 target_, bytes calldata data) external {
        target = target_;
        reenterCall = data;
    }

    function _hook() internal {
        if (address(target) == address(0) || reenterCall.length == 0) return;
        bytes memory data = reenterCall;
        reenterCall = "";
        ++attempts;
        (bool ok, bytes memory ret) = address(target).call(data);
        require(!ok, "re-entered through token");
        lastRevert = ret;
    }

    function transferFrom(address from, address to, uint256 value) public override returns (bool) {
        _hook();
        return super.transferFrom(from, to, value);
    }

    function transfer(address to, uint256 value) public override returns (bool) {
        _hook();
        return super.transfer(to, value);
    }
}
