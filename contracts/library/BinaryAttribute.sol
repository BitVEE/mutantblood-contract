// SPDX-License-Identifier: MIT
pragma solidity >= 0.8.19 < 0.9.0;

import "../definition/MutantBloodStruct_Attribute.sol";

library BinaryAttribute
{
    function checkAttributeID(bytes calldata attributes, uint256 attrID) external pure returns(bool)
    {
        for(uint256 i = 0; i < attributes.length;)
        {
            if(uint8(attributes[i]) == attrID)
            {
                return true;
            }
            else
            {
                i += 4;
            }
        }

        return false;
    }

    function getAttributeValue(bytes calldata attributes, uint256 attrID) external pure returns(uint256)
    {
        for(uint256 i = 0; i < attributes.length;)
        {
            if(uint8(attributes[i]) == attrID)
            {
                return uint256( uint32(uint8(attributes[i + 1])) << 16 | uint32(uint8(attributes[i + 2])) << 8 | uint8(attributes[i + 3]) );
            }
            else
            {
                i += 4;
            }
        }

        return 0;
    }

    /////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
    /////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
    function serializeAttribute(Attribute calldata attr) external pure returns(bytes memory)
    {
        bytes memory attributes = new bytes(4);
        
        attributes[0] = bytes1(attr.AttrID);
        attributes[1] = bytes1(uint8(attr.AttrValue >> 16));
        attributes[2] = bytes1(uint8(attr.AttrValue >> 8));
        attributes[3] = bytes1(uint8(attr.AttrValue & 0xff));

        return attributes;
    }
    
    function serializeAttributes(Attribute[] calldata attrList) external pure returns(bytes memory)
    {
        uint256 attrCount = attrList.length;
        uint256 attrIndex = 0;
        bytes memory attributes = new bytes(attrCount * 4);
        
        for(uint256 i = 0; i < attrCount; ++i)
        {
            attributes[attrIndex] = bytes1(attrList[i].AttrID);
            attrIndex++;

            attributes[attrIndex] = bytes1(uint8(attrList[i].AttrValue >> 16));
            attrIndex++;

            attributes[attrIndex] = bytes1(uint8(attrList[i].AttrValue >> 8));
            attrIndex++;

            attributes[attrIndex] = bytes1(uint8(attrList[i].AttrValue & 0xff));
            attrIndex++;
        }

        return attributes;
    }

    function deserializeAttributes(bytes calldata attributes) external pure returns(Attribute[] memory)
    {
        uint256 attrCount = attributes.length / 4;
        Attribute[] memory attrList = new Attribute[](attrCount);

        for(uint256 i = 0; i < attrCount; ++i)
        {
            uint256 m = i * 4;

            if((m + 3) >= attributes.length)
            {
                revert("attribute length err!");
            }

            attrList[i] = Attribute({
                                        AttrID: uint8(attributes[m]),
                                        AttrValue: (uint24(uint8(attributes[m + 1])) << 16) | (uint24(uint8(attributes[m + 2])) << 8) | (uint8(attributes[m + 3]))
                                    });
        }

        return attrList;
    }

    /////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
    /////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
    function pushAttribute(bytes storage attributes, uint256 attrID, uint256 attrValue) internal
    {
        //check
        for(uint256 i = 0; i < attributes.length;)
        {
            if(uint8(attributes[i]) == attrID)
            {
                revert("attribute repetition!");
            }
            else
            {
                if((i + 3) >= attributes.length)
                {
                    revert("attribute length err!");
                }
                
                i += 4;
            }
        }

        attributes.push(bytes1(uint8(attrID)));

        attributes.push(bytes1(uint8(attrValue >> 16)));
        attributes.push(bytes1(uint8(attrValue >> 8)));
        attributes.push(bytes1(uint8(attrValue & 0xff)));
    }

    function setAttribute(bytes storage attributes, uint256 attrID, uint256 attrValue) internal
    {
        for(uint256 i = 0; i < attributes.length;)
        {
            if(uint8(attributes[i]) == attrID)
            {
                if((i + 3) >= attributes.length)
                {
                    revert("attribute length err!");
                }

                attributes[i+1] = (bytes1(uint8(attrValue >> 16)));
                attributes[i+2] = (bytes1(uint8(attrValue >> 8)));
                attributes[i+3] = (bytes1(uint8(attrValue & 0xff)));

                return;
            }
            else
            {
                i += 4;
            }
        }

        revert("attribute not found!");
    }
}
