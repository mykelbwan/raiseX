// SPDX-License-Identifier: MIT

pragma solidity ^0.8.30;

import {ContractTransparencyConfig} from "../Interface/ContractTransparencyConfig.sol";

error DurationShouldBeGreaterThanZero();
error FundingTargetShouldBeGreaterThanZero();
error CampaignEnded();
error ZeroAmount();
error UnAuthorized();
error TargetMet();
error CampaignStillOngoing();
error AlreadyWithdrawn();
error WithdrawalFailed();
error DescriptionTooLong();

contract GoFundMe is ContractTransparencyConfig {
    struct Campaign {
        address creator;
        uint256 fundingTarget;
        uint256 endTime;
        uint256 raisedAmount;
        uint256 campaignId;
        string description;
        bool withdrawn;
    }

    struct ViewCampaign {
        uint256 fundingTarget;
        uint256 endTime;
        uint256 raisedAmount;
        string description;
        address creator;
        bool withdrawn;
        bool ended;
    }

    struct ViewCampaignCreator {
        uint256 campaignId;
        uint256 raisedAmt;
        string des;
        bool ended;
        bool withdrawn;
    }

    mapping(uint256 campaignId => Campaign) private campaigns;
    mapping(address creator => uint256[] campaignId) campaignCreator;

    uint256 private nextCampaignId;
    uint16 private maxdescriptionLength = 500;

    event CampaignCreated(
        uint256 indexed campaignId,
        uint256 fundingTarget,
        uint256 endTime,
        string description
    );
    event Funded(
        address indexed contributor,
        uint256 indexed campaignId,
        uint256 amount
    );
    event CampaignFundsWithdrawn(uint256 indexed campaignId, uint256 amount);

    function createGoFundMe(
        uint256 _fundingTarget,
        uint256 _durationInDays,
        string calldata _description
    ) external {
        if (_durationInDays == 0) revert DurationShouldBeGreaterThanZero();
        if (_fundingTarget == 0) revert FundingTargetShouldBeGreaterThanZero();
        if (bytes(_description).length > maxdescriptionLength)
            revert DescriptionTooLong();

        uint256 endTime = block.timestamp + (_durationInDays * 1 days);
        uint256 campaignId = nextCampaignId++;
        campaignCreator[msg.sender].push(campaignId);

        campaigns[campaignId] = Campaign({
            creator: msg.sender,
            fundingTarget: _fundingTarget,
            endTime: endTime,
            raisedAmount: 0,
            campaignId: campaignId,
            description: _description,
            withdrawn: false
        });

        emit CampaignCreated(campaignId, _fundingTarget, endTime, _description);
    }

    /// @notice fund a campaign (anonymous donations)
    function fund(uint256 _campaignId) external payable {
        Campaign storage c = campaigns[_campaignId];
        uint256 amount = msg.value;

        if (block.timestamp > c.endTime) revert CampaignEnded();
        if (amount < 0) revert ZeroAmount();
        c.raisedAmount += amount;
        emit Funded(msg.sender, _campaignId, amount);
    }

    /// @notice withdraw raised funds (only creator)
    function withDraw(uint256 _campaignId, address to) external {
        Campaign storage c = campaigns[_campaignId];
        if (c.creator != msg.sender) revert UnAuthorized();
        if (c.endTime > block.timestamp) revert CampaignStillOngoing();
        if (c.withdrawn) revert AlreadyWithdrawn();

        c.withdrawn = true;

        uint256 amount = c.raisedAmount;
        c.raisedAmount = 0;
        (bool ok, ) = payable(to).call{value: amount}("");
        if (!ok) revert WithdrawalFailed();
        emit CampaignFundsWithdrawn(_campaignId, amount);
    }

    function _hashEvent(
        string memory eventSignature
    ) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(eventSignature));
    }

    function visibilityRules() external pure returns (VisibilityConfig memory) {
        EventLogConfig[] memory eventLogConfigs = new EventLogConfig[](3);

        bytes32 createCampaignSig = _hashEvent(
            "CampaignCreated(uint256,uint256,uint256,string)"
        );
        Field[] memory relevantToCreateCampaign = new Field[](1);
        relevantToCreateCampaign[0] = Field.EVERYONE;
        eventLogConfigs[0] = EventLogConfig(
            createCampaignSig,
            relevantToCreateCampaign
        );

        bytes32 fundedCampaignSig = _hashEvent(
            "Funded(address,uint256,uint256)"
        );
        Field[] memory relevantToFundedCampaign = new Field[](1);
        relevantToCreateCampaign[0] = Field.TOPIC1;
        eventLogConfigs[1] = EventLogConfig(
            fundedCampaignSig,
            relevantToFundedCampaign
        );

        bytes32 campaignFundsWithdrawnSig = _hashEvent(
            "CampaignFundsWithdrawn(uint256,uint256)"
        );
        Field[] memory relevantToCampaignFundsWithdrawn = new Field[](1);
        relevantToCampaignFundsWithdrawn[0] = Field.EVERYONE;
        eventLogConfigs[2] = EventLogConfig(
            campaignFundsWithdrawnSig,
            relevantToCampaignFundsWithdrawn
        );

        return VisibilityConfig(ContractCfg.PRIVATE, eventLogConfigs);
    }

    function viewCampaign(
        uint256 _campaignId
    ) external view returns (ViewCampaign memory) {
        Campaign memory campaign = campaigns[_campaignId];

        bool hasEnded = block.timestamp >= campaign.endTime;

        return
            ViewCampaign({
                fundingTarget: campaign.fundingTarget,
                endTime: campaign.endTime,
                raisedAmount: campaign.raisedAmount,
                description: campaign.description,
                creator: campaign.creator,
                withdrawn: campaign.withdrawn,
                ended: hasEnded
            });
    }

    function viewCampaignCreator(
        address creator
    ) external view returns (ViewCampaignCreator[] memory) {
        uint256[] memory creatorCampaigns = campaignCreator[creator];
        uint256 count = creatorCampaigns.length;

        ViewCampaignCreator[] memory viewC = new ViewCampaignCreator[](count);

        for (uint256 i = 0; i < count; i++) {
            uint256 cId = creatorCampaigns[i];
            Campaign memory c = campaigns[cId];
            bool ended = block.timestamp >= c.endTime;

            viewC[i] = ViewCampaignCreator({
                campaignId: c.campaignId,
                raisedAmt: c.raisedAmount,
                des: c.description,
                ended: ended,
                withdrawn: c.withdrawn
            });
        }

        return viewC;
    }
}
