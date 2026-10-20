// SPDX-License-Identifier: MIT
pragma solidity >=0.8.19 <0.9.0;

import "../definition/MutantBloodStruct_Pet.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721.sol";

interface ITokenPet is IERC721 {
    function getPetData(uint256 tokenID) external view returns (Pet memory);

    function mint(
        address ownerAddr,
        uint256 petID,
        bytes calldata attributes
    ) external returns (uint256);

    function burn(uint256 tokenID) external;

    function setPetAttributes(
        uint256 tokenID,
        bytes calldata attributes
    ) external;
}
