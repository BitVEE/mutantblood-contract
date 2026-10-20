// SPDX-License-Identifier: MIT
pragma solidity >=0.8.19 <0.9.0;

import "../definition/MutantBloodStruct_Part.sol";
import "../definition/MutantBloodStruct_Attribute.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721.sol";

interface ITokenPart is IERC721 {
    function getPartData(uint256 tokenID) external view returns (Part memory);

    function getPartDataByIndex(
        address ownerAddr,
        uint256 tokenIndex
    ) external view returns (Part memory);

    function getPartAttribute(
        uint256 tokenID
    ) external view returns (Attribute[] memory);

    function getPartAttributeValue(
        uint256 tokenID,
        uint256 attrID
    ) external view returns (uint256);

    function mint(Part memory newPart) external returns (uint256);

    function burn(uint256 tokenID) external;
}
