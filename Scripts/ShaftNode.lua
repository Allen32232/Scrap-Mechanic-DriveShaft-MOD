------------
-- ShaftNode
-- 传动轴端点
------------

ShaftNode = class()

ShaftNode.connectionInput = sm.interactable.connectionType.logic
ShaftNode.connectionOutput = sm.interactable.connectionType.logic
ShaftNode.maxParentCount = 1
ShaftNode.maxChildCount = 1

ShaftNode.colorHighlight = sm.color.new("#6BB5FF")
ShaftNode.colorNormal = sm.color.new("#4A90D9")

ShaftNode.NODE_UUID = sm.uuid.new("d5a0f001-0001-4d53-8001-000000000001")


function ShaftNode:client_canInteract()
    return false
end
