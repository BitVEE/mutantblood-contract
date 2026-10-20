// SPDX-License-Identifier: MIT
pragma solidity >= 0.8.19 < 0.9.0;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/**
 * Test-only payment token matching the 18-decimal BSC USDT interface.
 */
contract MockUSDT18 is ERC20 {
    address private m_Owner;

    constructor(address ownerAddr) ERC20("Mock BSC USDT", "USDT") {
        require(ownerAddr != address(0), "owner addr err");
        m_Owner = ownerAddr;
        _mint(ownerAddr, 10_000_000 * 10 ** decimals());
    }

    modifier onlyOwner() {
        require(msg.sender == m_Owner, "permission denied");
        _;
    }

    function faucet(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function mint(address to, uint256 amount) external onlyOwner {
        _mint(to, amount);
    }
}
