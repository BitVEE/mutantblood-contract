// SPDX-License-Identifier: MIT
pragma solidity >= 0.8.19 < 0.9.0;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/**
 * MockUSDV：测试用稳定币（模拟 USDC，6位小数）
 * 仅用于本地沙盒和 BSC 测试网，主网部署时替换为真实 USDC 地址
 */
contract MockUSDV is ERC20
{
    address private m_Owner;
    uint8   private constant DECIMALS = 6;

    constructor(address ownerAddr) ERC20("USD Venom", "USDV")
    {
        require(ownerAddr != address(0), "owner addr err");
        m_Owner = ownerAddr;
        // 初始发行 10,000,000 USDV 给 owner（够测试用）
        _mint(ownerAddr, 10_000_000 * 10 ** DECIMALS);
    }

    modifier onlyOwner() {
        require(msg.sender == m_Owner, "permission denied");
        _;
    }

    function decimals() public pure override returns (uint8) {
        return DECIMALS;
    }

    // 测试辅助：任何账户可以给自己 mint（仅测试网）
    function faucet(address to, uint256 amount) external {
        _mint(to, amount);
    }

    // Owner 可以 mint 给指定地址
    function mint(address to, uint256 amount) external onlyOwner {
        _mint(to, amount);
    }
}
