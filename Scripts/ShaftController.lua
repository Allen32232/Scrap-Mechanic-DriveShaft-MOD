----------------------
-- ShaftController
-- 双万向节传动轴控制器
----------------------

ShaftController = class()

ShaftController.connectionInput = sm.interactable.connectionType.logic
ShaftController.connectionOutput = sm.interactable.connectionType.logic
ShaftController.maxParentCount = 255
ShaftController.maxChildCount = 255

ShaftController.colorHighlight = sm.color.new("#8B7BAD")
ShaftController.colorNormal = sm.color.new("#6B5B95")

---- 常量定义 ----
-- UUID
ShaftController.NODE_UUID = sm.uuid.new("d5a0f001-0001-4d53-8001-000000000001")            -- 节点 1x1
ShaftController.NODE_1x2_UUID = sm.uuid.new("d5a0f007-0007-4d53-8007-000000000007")      -- 节点 1x2
ShaftController.NODE_2x2_UUID = sm.uuid.new("d5a0f008-0008-4d53-8008-000000000008")      -- 节点 2x2
ShaftController.CONTROLLER_UUID = sm.uuid.new("d5a0f002-0002-4d53-8002-000000000002")    -- 控制器
ShaftController.SENSOR_UUID = sm.uuid.new("d5a0f003-0003-4d53-8003-000000000003")        -- 传感器
ShaftController.DRIVESHAFT_UUID = sm.uuid.new("d5a0f004-0004-4d53-8004-000000000004")  -- 传动轴
ShaftController.SPIDER_UUID = sm.uuid.new("d5a0f005-0005-4d53-8005-000000000005")      -- 十字轴
ShaftController.YOKE_UUID = sm.uuid.new("d5a0f006-0006-4d53-8006-000000000006")        -- 叉头

-- 几何与缩放
ShaftController.BLOCK_SIZE = 0.25                 -- 0.25m/格
ShaftController.MIN_DISTANCE = 0.001              -- 最小距离阈值
ShaftController.DEFAULT_JOINT_SCALE = 1.0         -- 万向节缩放
ShaftController.DEFAULT_SHAFT_SCALE = 1.0         -- 传动轴粗细
ShaftController.DEFAULT_COLOR = 0x202020FF        -- 默认颜色
ShaftController.FORK_OFFSET_MAX = 0.085           -- 最大偏移量
ShaftController.FORK_ARM_LENGTH = 0.15            -- 叉臂长度
ShaftController.DRIVESHAFT_MODEL_LENGTH = 0.18    -- 模型原始长度

-- 更新与数学
ShaftController.FIXED_DT = 0.025  -- 固定更新间隔 = 1/40 秒
ShaftController.UNIT_X = sm.vec3.new(1, 0, 0)     -- 单位向量X
ShaftController.UNIT_Y = sm.vec3.new(0, 1, 0)     -- 单位向量Y
ShaftController.UNIT_Z = sm.vec3.new(0, 0, 1)     -- 单位向量Z
ShaftController.TWO_PI = math.pi * 2              -- 2π
ShaftController.QUAT_EPSILON = 1e-6               -- 四元数计算最小阈值


---- 服务端 ----

function ShaftController:server_onCreate()
    local C = ShaftController
    self.setting = self.storage:load()
    if not self.setting then
        self.setting = {
            color = sm.color.new(C.DEFAULT_COLOR),
            jointScale = C.DEFAULT_JOINT_SCALE,
            shaftScale = C.DEFAULT_SHAFT_SCALE
        }
    end
    -- 兼容旧存档：移除废弃字段
    self.setting.reverse = nil
    if self.setting.jointScale == nil then
        self.setting.jointScale = self.setting.radius or C.DEFAULT_JOINT_SCALE
    end
    if self.setting.shaftScale == nil then
        self.setting.shaftScale = C.DEFAULT_SHAFT_SCALE
    end
    self.setting.radius = nil

    self.sensorDataCache = {}
    self.network:setClientData({ setting = self.setting, sensorData = {} })
end


function ShaftController:server_onFixedUpdate()
    local C = ShaftController
    local parents = self.interactable:getParents(sm.interactable.connectionType.logic)

    local sensorData = {}
    local hasChanges = false

    for _, parent in ipairs(parents) do
        if parent and sm.exists(parent) then
            local shape = parent.shape
            if shape and sm.exists(shape) and shape:getShapeUuid() == C.SENSOR_UUID then
                local id = parent:getId()
                local data = parent:getPublicData()
                if data then
                    sensorData[id] = {
                        reverse = data.reverse or false,
                        ratio = data.ratio or 1.0
                    }
                    -- 检查是否有变化
                    local cached = self.sensorDataCache[id]
                    if not cached or cached.reverse ~= data.reverse or cached.ratio ~= data.ratio then
                        hasChanges = true
                    end
                end
            end
        end
    end

    -- 检查传感器数量是否变化
    local cachedCount = 0
    for _ in pairs(self.sensorDataCache) do cachedCount = cachedCount + 1 end
    local newCount = 0
    for _ in pairs(sensorData) do newCount = newCount + 1 end
    if cachedCount ~= newCount then
        hasChanges = true
    end

    if hasChanges then
        self.sensorDataCache = sensorData
        self.network:setClientData({ setting = self.setting, sensorData = sensorData })
    end
end


function ShaftController:server_onDestroy()
end


function ShaftController:sv_isValidColor(color)
    if not color then return false end
    return type(color.r) == "number"
       and type(color.g) == "number"
       and type(color.b) == "number"
end


function ShaftController:sv_updateSettings(newSettings)
    if newSettings.color and self:sv_isValidColor(newSettings.color) then
        self.setting.color = newSettings.color
    end

    if newSettings.jointScale and type(newSettings.jointScale) == "number" then
        self.setting.jointScale = math.max(0.25, math.min(5.0, newSettings.jointScale))
    end

    if newSettings.shaftScale and type(newSettings.shaftScale) == "number" then
        self.setting.shaftScale = math.max(0.25, math.min(5.0, newSettings.shaftScale))
    end

    self.storage:save(self.setting)
    self.network:setClientData({ setting = self.setting, sensorData = self.sensorDataCache or {} })
end


---- 客户端 ----

function ShaftController:client_onCreate()
    local C = ShaftController

    self.currentSettings = {
        color = sm.color.new(C.DEFAULT_COLOR),
        jointScale = C.DEFAULT_JOINT_SCALE,
        shaftScale = C.DEFAULT_SHAFT_SCALE
    }

    self.sensorData = {}

    self.sensorAnglePrev = 0
    self.sensorAngleCurr = 0
    self.fixedAccumulator = 0

    self.shaftPairs = {}
    self.cachedPairIds = {}
    self.cachedChildCount = 0
    self.effectPools = {}
    self.hasSensor = false

    -- 节点 UUID 集合：用于验证连线中的节点类型
    -- 所有节点 hull Y 均为 1，传动轴方向无需额外偏移
    self.nodeUuids = {
        [tostring(C.NODE_UUID)]     = true,
        [tostring(C.NODE_1x2_UUID)] = true,
        [tostring(C.NODE_2x2_UUID)] = true
    }

    self.currentLang = nil
    self.langText = nil
    self:cl_loadLanguage()

    self.gui = nil
    self:cl_initGui()
end


function ShaftController:cl_loadLanguage(language)
    local lang = language or sm.gui.getCurrentLanguage()
    local newLang = (lang == "Chinese") and "Chinese" or "English"

    -- 语言未变化时跳过加载
    if newLang == self.currentLang then
        return
    end

    self.currentLang = newLang
    self.langText = sm.json.open("$MOD_DATA/Gui/Language/" .. newLang .. "/ShaftController.json")
end


function ShaftController:client_onLanguageChange(language)
    self:cl_loadLanguage(language)
    self:cl_applyLanguageToGui()
end


function ShaftController:cl_applyLanguageToGui()
    if not self.gui or not self.langText then return end
    self.gui:setText("guiTitle", self.langText.guiTitle or "#ffcc00DriveShaft Settings")
    self.gui:setText("ColorLabel", self.langText.colorLabel or "#ffffffColor:")
    self.gui:setText("JointScaleLabel", self.langText.jointScaleLabel or "#ffffffJoint Size:")
    self.gui:setText("ShaftScaleLabel", self.langText.shaftScaleLabel or "#ffffffShaft Size:")
end


function ShaftController:client_onDestroy()
    self:cl_destroyAll()
    self:cl_destroyPool()
    if self.gui then
        if self.gui:isActive() then
            self.gui:close()
        end
        self.gui:destroy()
        self.gui = nil
    end
end


function ShaftController:client_onClientDataUpdate(data)
    if data.setting then
        self.currentSettings = data.setting
    end

    if data.sensorData then
        self.sensorData = data.sensorData
    end

    if self.gui and self.gui:isActive() then
        self:cl_updateGuiDisplay()
    end
end


function ShaftController:client_onFixedUpdate(dt)
    local C = ShaftController

    -- 检测节点配对变化（包括控制器子节点和节点间连线）
    local nodePairs = self:cl_findNodePairs()

    local currentIds = {}
    for i, pair in ipairs(nodePairs) do
        currentIds[i] = { pair[1]:getId(), pair[2]:getId() }
    end

    local pairsChanged = #currentIds ~= #self.cachedPairIds
    if not pairsChanged then
        for i, ids in ipairs(currentIds) do
            local cached = self.cachedPairIds[i]
            if not cached or cached[1] ~= ids[1] or cached[2] ~= ids[2] then
                pairsChanged = true
                break
            end
        end
    end

    if pairsChanged then
        for _, oldPair in ipairs(self.shaftPairs) do
            self:cl_destroyShaftPair(oldPair)
        end
        self.shaftPairs = {}
        for i, pair in ipairs(nodePairs) do
            self.shaftPairs[i] = self:cl_createShaftPair(pair[1], pair[2])
        end
        self.cachedPairIds = currentIds
    end

    local rotationSpeed = self:cl_getSensorRotationSpeed()
    self.hasSensor = rotationSpeed ~= nil
    if rotationSpeed then
        self.sensorAnglePrev = self.sensorAngleCurr
        self.sensorAngleCurr = self.sensorAngleCurr + rotationSpeed * C.FIXED_DT

        -- 角度归一化：同步调整 prev 和 curr，保持差值不变以确保插值正确
        if self.sensorAngleCurr > C.TWO_PI then
            self.sensorAngleCurr = self.sensorAngleCurr - C.TWO_PI
            self.sensorAnglePrev = self.sensorAnglePrev - C.TWO_PI
        elseif self.sensorAngleCurr < -C.TWO_PI then
            self.sensorAngleCurr = self.sensorAngleCurr + C.TWO_PI
            self.sensorAnglePrev = self.sensorAnglePrev + C.TWO_PI
        end
    end

    self.fixedAccumulator = 0
end


function ShaftController:client_onUpdate(dt)
    local C = ShaftController

    if #self.shaftPairs == 0 then
        self:cl_destroyAll()
        return
    end

    self.fixedAccumulator = self.fixedAccumulator + dt
    local alpha = math.min(self.fixedAccumulator / C.FIXED_DT, 1)
    local sensorAngle = self.sensorAnglePrev + (self.sensorAngleCurr - self.sensorAnglePrev) * alpha
    local color = self.currentSettings.color or sm.color.new(C.DEFAULT_COLOR)

    -- 预计算三角函数，避免循环内重复计算
    local cosA, sinA
    if self.hasSensor then
        cosA = math.cos(sensorAngle)
        sinA = math.sin(sensorAngle)
    end

    for _, pair in ipairs(self.shaftPairs) do
        if not self:cl_isValidNode(pair.nodeA) or not self:cl_isValidNode(pair.nodeB) then
            goto continue
        end
        self:cl_renderPairInterpolated(pair, self.hasSensor, cosA, sinA, color)
        ::continue::
    end
end


---- 查询函数 ----

function ShaftController:cl_findNodePairs()
    local allPairs = {}
    local globalVisited = {}

    local children = self.interactable:getChildren(sm.interactable.connectionType.logic)
    local startNodes = {}
    for _, child in ipairs(children) do
        if self:cl_isValidNode(child) then
            startNodes[#startNodes + 1] = child
        end
    end

    for _, startNode in ipairs(startNodes) do
        if not globalVisited[startNode:getId()] then
            local nodeChain = {}
            local current = startNode

            while current do
                local id = current:getId()
                if globalVisited[id] then break end
                globalVisited[id] = true
                nodeChain[#nodeChain + 1] = current

                local nextNode = nil
                for _, child in ipairs(current:getChildren(sm.interactable.connectionType.logic)) do
                    if self:cl_isValidNode(child) and not globalVisited[child:getId()] then
                        nextNode = child
                        break
                    end
                end
                if not nextNode then
                    for _, parent in ipairs(current:getParents(sm.interactable.connectionType.logic)) do
                        if self:cl_isValidNode(parent) and not globalVisited[parent:getId()] then
                            nextNode = parent
                            break
                        end
                    end
                end
                current = nextNode
            end

            for i = 1, #nodeChain - 1, 2 do
                allPairs[#allPairs + 1] = { nodeChain[i], nodeChain[i + 1] }
            end
        end
    end

    return allPairs
end


function ShaftController:cl_isValidNode(interactable)
    if not interactable or not sm.exists(interactable) then return false end

    local shape = interactable.shape
    if not shape or not sm.exists(shape) then return false end

    return self.nodeUuids[tostring(shape:getShapeUuid())] == true
end


function ShaftController:cl_createShaftPair(nodeA, nodeB)
    return {
        nodeA = nodeA,
        nodeB = nodeB,
        idA = nodeA:getId(),
        idB = nodeB:getId(),
        innerForkA = {},
        innerForkB = {},
        crossA = {},
        crossB = {},
        outerForkA = {},
        outerForkB = {},
        middleShaft = nil
    }
end


function ShaftController:cl_destroyShaftPair(pair)
    self:cl_destroyFork(pair.innerForkA)
    self:cl_destroyFork(pair.innerForkB)
    self:cl_destroyFork(pair.crossA)
    self:cl_destroyFork(pair.crossB)
    self:cl_destroyFork(pair.outerForkA)
    self:cl_destroyFork(pair.outerForkB)
    if pair.middleShaft and pair.middleShaft.effect then
        self:cl_releaseEffect(pair.middleShaft.effect, pair.middleShaft.uuid)
        pair.middleShaft = nil
    end
end


function ShaftController:cl_getSensorRotationSpeed()
    local C = ShaftController

    local parents = self.interactable:getParents(sm.interactable.connectionType.logic)

    local totalSpeed = 0
    local sensorCount = 0

    for _, parent in ipairs(parents) do
        if not parent or not sm.exists(parent) then
            goto continue
        end
        local shape = parent.shape
        if not shape or not sm.exists(shape) then
            goto continue
        end
        if shape:getShapeUuid() ~= C.SENSOR_UUID then
            goto continue
        end
        local body = shape:getBody()
        if body and sm.exists(body) then
            local sensorY = shape.worldRotation * C.UNIT_Y
            local angVel = body:getAngularVelocity()
            local speed = angVel:dot(sensorY)

            -- 应用传感器自身的设置（反转和倍率），从服务端同步的缓存中读取
            local sensorSettings = self.sensorData[parent:getId()]
            if sensorSettings then
                if sensorSettings.reverse then
                    speed = -speed
                end
                if sensorSettings.ratio then
                    speed = speed * sensorSettings.ratio
                end
            end

            totalSpeed = totalSpeed + speed
            sensorCount = sensorCount + 1
        end
        ::continue::
    end

    if sensorCount > 0 then
        return totalSpeed / sensorCount
    end
    return nil
end


---- 万向节渲染 ----

--[[
双万向节通过串联两个万向节实现等速传动，消除单万向节的角速度波动。
结构: 节点A -> [内叉A-十字轴A-外叉A] =传动轴= [外叉B-十字轴B-内叉B] -> 节点B

核心约束:
  - 十字轴X轴被内叉夹持 (crossX = innerX)，Z轴垂直于传动轴
  - 外叉X轴由十字轴Z轴正交化得到 (Gram-Schmidt)
  - 等速传动关键: outerX_B = outerX_A，确保两侧相位补偿
]]

function ShaftController:cl_renderPairInterpolated(pair, hasSensor, cosA, sinA, color)
    local C = ShaftController
    local shapeA = pair.nodeA.shape
    local shapeB = pair.nodeB.shape

    local posA = shapeA:getInterpolatedWorldPosition()
    local posB = shapeB:getInterpolatedWorldPosition()

    local innerX_A = shapeA:getInterpolatedRight()
    local innerY_A = shapeA:getInterpolatedAt()
    local innerZ_A = shapeA:getInterpolatedUp()

    local innerX_B = shapeB:getInterpolatedRight()
    local innerY_B = shapeB:getInterpolatedAt()
    local innerZ_B = shapeB:getInterpolatedUp()

    if hasSensor then
        local baseX = innerX_A
        local baseZ = innerZ_A
        innerX_A = baseX * cosA + baseZ * sinA
        innerZ_A = baseZ * cosA - baseX * sinA
    end

    local jointScale = self.currentSettings.jointScale or C.DEFAULT_JOINT_SCALE
    -- 线性偏移：缩放0.25→-0.1，缩放5→+0.1
    local forkOffset = C.FORK_OFFSET_MAX * (jointScale - 0.25) / 4.75 * 2 - C.FORK_OFFSET_MAX
    local forkArmLength = C.FORK_ARM_LENGTH * jointScale

    local innerPosA = posA + innerY_A * forkOffset
    local innerPosB = posB + innerY_B * forkOffset

    local crossCenterA = innerPosA + innerY_A * forkArmLength
    local crossCenterB = innerPosB + innerY_B * forkArmLength

    local shaftVec = crossCenterB - crossCenterA
    local shaftDir = self:cl_safeNormalize(shaftVec, innerY_A)

    local crossX_A = innerX_A
    local crossZ_A = self:cl_safeNormalize(innerX_A:cross(shaftDir), innerZ_A)
    local crossY_A = crossZ_A:cross(crossX_A)

    local outerCenterA = crossCenterA + shaftDir * forkArmLength
    local outerY_A = -shaftDir
    local outerX_A = self:cl_safeNormalize(crossZ_A - outerY_A * crossZ_A:dot(outerY_A), crossZ_A)
    local outerZ_A = outerX_A:cross(outerY_A)

    local outerX_B = outerX_A
    local crossZ_B = outerX_B
    local crossX_B = self:cl_safeNormalize(innerY_B:cross(crossZ_B), innerX_B)
    local crossY_B = crossZ_B:cross(crossX_B)

    local outerCenterB = crossCenterB - shaftDir * forkArmLength
    local outerY_B = shaftDir
    local outerX_B_aligned = crossZ_B - outerY_B * crossZ_B:dot(outerY_B)
    outerX_B = self:cl_safeNormalize(outerX_B_aligned, outerX_B)
    local outerZ_B = outerX_B:cross(outerY_B)

    local innerX_A_driven = innerX_A
    local innerY_A_driven = innerY_A
    local innerZ_A_driven = innerZ_A

    local innerX_B_driven = crossX_B
    local innerY_B_driven = innerY_B
    local innerZ_B_driven = innerX_B_driven:cross(innerY_B_driven)

    self:cl_renderFork(pair.innerForkA, innerPosA, innerX_A_driven, innerY_A_driven, innerZ_A_driven, color)
    self:cl_renderFork(pair.innerForkB, innerPosB, innerX_B_driven, innerY_B_driven, innerZ_B_driven, color)

    self:cl_renderCross(pair.crossA, crossCenterA, crossX_A, crossY_A, crossZ_A, color)
    self:cl_renderCross(pair.crossB, crossCenterB, crossX_B, crossY_B, crossZ_B, color)

    self:cl_renderFork(pair.outerForkA, outerCenterA, outerX_A, outerY_A, outerZ_A, color)
    self:cl_renderFork(pair.outerForkB, outerCenterB, outerX_B, outerY_B, outerZ_B, color)

    pair.middleShaft = self:cl_renderMiddleShaftForPair(pair.middleShaft, outerCenterA, outerCenterB, outerX_A, color)
end


function ShaftController:cl_renderFork(fork, centerPos, axisX, axisY, axisZ, color)
    local C = ShaftController

    local jointScale = self.currentSettings.jointScale or C.DEFAULT_JOINT_SCALE
    local yokeRot = self:cl_quatFromAxes(axisX, axisY, axisZ)
    local yokeScale = sm.vec3.new(jointScale, jointScale, jointScale)

    self:cl_updateEffect(fork, "yoke", centerPos, yokeRot, yokeScale, color, C.YOKE_UUID)
end


function ShaftController:cl_renderCross(cross, center, axisX, axisY, axisZ, color)
    local C = ShaftController

    local jointScale = self.currentSettings.jointScale or C.DEFAULT_JOINT_SCALE
    local spiderRot = self:cl_quatFromAxes(axisX, axisY, axisZ)
    local spiderScale = sm.vec3.new(jointScale, jointScale, jointScale)

    self:cl_updateEffect(cross, "spider", center, spiderRot, spiderScale, color, C.SPIDER_UUID)
end


function ShaftController:cl_renderMiddleShaftForPair(middleShaft, posA, posB, outerAxisX, color)
    local C = ShaftController

    local direction = posB - posA
    local length = direction:length()

    if length < C.MIN_DISTANCE then return middleShaft end

    local center = (posA + posB) * 0.5
    local shaftDir = direction:normalize()

    local shaftRot = self:cl_buildShaftRotation(shaftDir, outerAxisX)
    local userShaftScale = self.currentSettings.shaftScale or C.DEFAULT_SHAFT_SCALE
    local lengthScale = length / C.DRIVESHAFT_MODEL_LENGTH
    local shaftScale = sm.vec3.new(userShaftScale, userShaftScale, lengthScale)

    if not middleShaft then
        middleShaft = { effect = nil, uuid = C.DRIVESHAFT_UUID }
    end

    if not middleShaft.effect or not sm.exists(middleShaft.effect) then
        middleShaft.effect = self:cl_acquireEffect(C.DRIVESHAFT_UUID)
        middleShaft.uuid = C.DRIVESHAFT_UUID
    end

    local offsetPos, offsetRot = self:cl_worldToLocal(center, shaftRot)

    middleShaft.effect:setOffsetPosition(offsetPos)
    middleShaft.effect:setOffsetRotation(offsetRot)
    middleShaft.effect:setScale(shaftScale)
    middleShaft.effect:setParameter("color", color)

    return middleShaft
end


function ShaftController:cl_buildShaftRotation(zDir, refX)
    local C = ShaftController
    local xDir = (refX - zDir * refX:dot(zDir))
    local xLen = xDir:length()
    if xLen > C.MIN_DISTANCE then
        xDir = xDir:normalize()
    else
        local fallback = C.UNIT_X
        if math.abs(zDir:dot(fallback)) > 0.9 then
            fallback = C.UNIT_Y
        end
        xDir = (fallback - zDir * fallback:dot(zDir)):normalize()
    end

    local yDir = zDir:cross(xDir)

    return self:cl_quatFromAxes(xDir, yDir, zDir)
end


function ShaftController:cl_quatFromAxes(xAxis, yAxis, zAxis)
    local C = ShaftController
    local m00, m10, m20 = xAxis.x, xAxis.y, xAxis.z
    local m01, m11, m21 = yAxis.x, yAxis.y, yAxis.z
    local m02, m12, m22 = zAxis.x, zAxis.y, zAxis.z

    local trace = m00 + m11 + m22
    local x, y, z, w

    if trace > 0 then
        local s = math.max(math.sqrt(trace + 1) * 2, C.QUAT_EPSILON)
        w = 0.25 * s
        x = (m21 - m12) / s
        y = (m02 - m20) / s
        z = (m10 - m01) / s
    elseif m00 > m11 and m00 > m22 then
        local s = math.max(math.sqrt(1 + m00 - m11 - m22) * 2, C.QUAT_EPSILON)
        w = (m21 - m12) / s
        x = 0.25 * s
        y = (m01 + m10) / s
        z = (m02 + m20) / s
    elseif m11 > m22 then
        local s = math.max(math.sqrt(1 + m11 - m00 - m22) * 2, C.QUAT_EPSILON)
        w = (m02 - m20) / s
        x = (m01 + m10) / s
        y = 0.25 * s
        z = (m12 + m21) / s
    else
        local s = math.max(math.sqrt(1 + m22 - m00 - m11) * 2, C.QUAT_EPSILON)
        w = (m10 - m01) / s
        x = (m02 + m20) / s
        y = (m12 + m21) / s
        z = 0.25 * s
    end

    return sm.quat.new(x, y, z, w)
end


---- 辅助函数 ----

function ShaftController:cl_safeNormalize(vec, fallback)
    local len = vec:length()
    if len > ShaftController.MIN_DISTANCE then
        return vec:normalize()
    end
    return fallback
end


function ShaftController:cl_worldToLocal(worldPos, worldRot)
    local ctrlPos = self.shape:getInterpolatedWorldPosition()
    local ctrlRot = self:cl_quatFromAxes(
        self.shape:getInterpolatedRight(),
        self.shape:getInterpolatedAt(),
        self.shape:getInterpolatedUp()
    )
    local invRot = sm.quat.inverse(ctrlRot)
    return invRot * (worldPos - ctrlPos), invRot * worldRot
end


function ShaftController:cl_acquireEffect(uuid)
    local uuidStr = tostring(uuid)
    local pools = self.effectPools

    if not pools[uuidStr] then
        pools[uuidStr] = {}
    end

    local pool = pools[uuidStr]
    while #pool > 0 do
        local effect = table.remove(pool)
        if effect and sm.exists(effect) then
            return effect
        end
    end

    local effect = sm.effect.createEffect("ShapeRenderable", self.interactable)
    effect:setParameter("uuid", uuid)
    effect:start()
    return effect
end


function ShaftController:cl_releaseEffect(effect, uuid)
    if effect and sm.exists(effect) then
        effect:setOffsetPosition(sm.vec3.zero())
        effect:setScale(sm.vec3.zero())

        local uuidStr = tostring(uuid)
        if not self.effectPools[uuidStr] then
            self.effectPools[uuidStr] = {}
        end
        local pool = self.effectPools[uuidStr]
        pool[#pool + 1] = effect
    end
end


function ShaftController:cl_updateEffect(container, name, worldPos, worldRot, scale, color, uuid)
    local entry = container[name]

    if not entry or type(entry) ~= "table" or not entry.effect then
        entry = { effect = nil, uuid = uuid }
        container[name] = entry
    end

    if not entry.effect or not sm.exists(entry.effect) then
        entry.effect = self:cl_acquireEffect(uuid)
        entry.uuid = uuid
    end

    local offsetPos, offsetRot = self:cl_worldToLocal(worldPos, worldRot)

    entry.effect:setOffsetPosition(offsetPos)
    entry.effect:setOffsetRotation(offsetRot)
    entry.effect:setScale(scale)
    entry.effect:setParameter("color", color)
end


function ShaftController:cl_destroyFork(fork)
    for name, entry in pairs(fork) do
        if entry and entry.effect then
            self:cl_releaseEffect(entry.effect, entry.uuid)
        end
        fork[name] = nil
    end
end


function ShaftController:cl_destroyAll()
    for _, pair in ipairs(self.shaftPairs) do
        self:cl_destroyShaftPair(pair)
    end
    self.shaftPairs = {}
    self.cachedPairIds = {}
end


function ShaftController:cl_destroyPool()
    for _, pool in pairs(self.effectPools) do
        for _, effect in ipairs(pool) do
            if effect and sm.exists(effect) then
                effect:destroy()
            end
        end
    end
    self.effectPools = {}
end


---- GUI ----

function ShaftController:cl_initGui()
    self.gui = sm.gui.createGuiFromLayout("$MOD_DATA/Gui/Layouts/ShaftController.layout")
    self.gui:setTextAcceptedCallback("ColorHexInput", "cl_onColorAccepted")
    self.gui:setTextAcceptedCallback("JointScaleInput", "cl_onJointScaleAccepted")
    self.gui:setTextAcceptedCallback("ShaftScaleInput", "cl_onShaftScaleAccepted")
    self.gui:setTextChangedCallback("ColorHexInput", "cl_onColorChanged")
    self.gui:setTextChangedCallback("JointScaleInput", "cl_onJointScaleChanged")
    self.gui:setTextChangedCallback("ShaftScaleInput", "cl_onShaftScaleChanged")
    self.gui:setOnCloseCallback("cl_onGuiClose")

    self.pendingColor = nil
    self.pendingJointScale = nil
    self.pendingShaftScale = nil
end


function ShaftController:cl_updateGuiDisplay()
    if not self.gui or not self.currentSettings then return end

    if self.currentSettings.color then
        local hex6 = string.sub(self.currentSettings.color:getHexStr(), 1, 6)
        self.gui:setText("ColorHexInput", string.upper(hex6))
    end

    local jointScale = self.currentSettings.jointScale or ShaftController.DEFAULT_JOINT_SCALE
    self.gui:setText("JointScaleInput", string.format("%g", jointScale))

    local shaftScale = self.currentSettings.shaftScale or ShaftController.DEFAULT_SHAFT_SCALE
    self.gui:setText("ShaftScaleInput", string.format("%g", shaftScale))
end


function ShaftController:client_onInteract(_, state)
    if state and self.gui then
        self:cl_loadLanguage()
        self:cl_applyLanguageToGui()
        self:cl_updateGuiDisplay()
        self.gui:open()
        self.pendingColor = nil
        self.pendingJointScale = nil
        self.pendingShaftScale = nil
    end
end


function ShaftController:client_canInteract()
    local text = (self.langText and self.langText.interactionText) or "DriveShaft Settings"
    sm.gui.setInteractionText("", sm.gui.getKeyBinding("Use", true), " " .. text)
    return true
end


function ShaftController:cl_onColorAccepted(_, text)
    if not self.gui then return end

    local C = ShaftController
    local color = self:cl_parseColor(text)

    if color then
        self.network:sendToServer("sv_updateSettings", { color = color })
        local hex = text:gsub("#", ""):gsub(" ", ""):upper()
        self.gui:setText("ColorHexInput", hex:sub(1, 6))
    else
        if self.currentSettings and self.currentSettings.color then
            local currentHex = self.currentSettings.color:getHexStr():sub(1, 6):upper()
            self.gui:setText("ColorHexInput", currentHex)
        else
            -- bit 库兼容性处理
            local defaultHex = string.format("%06X", math.floor(C.DEFAULT_COLOR / 256))
            self.gui:setText("ColorHexInput", defaultHex)
        end
    end

    self.pendingColor = nil
end


function ShaftController:cl_onJointScaleAccepted(_, text)
    if not self.gui then return end

    local scale = self:cl_parseScale(text)

    if scale then
        self.network:sendToServer("sv_updateSettings", { jointScale = scale })
        self.gui:setText("JointScaleInput", string.format("%g", scale))
    else
        local current = (self.currentSettings and self.currentSettings.jointScale) or ShaftController.DEFAULT_JOINT_SCALE
        self.gui:setText("JointScaleInput", string.format("%g", current))
    end

    self.pendingJointScale = nil
end


function ShaftController:cl_onShaftScaleAccepted(_, text)
    if not self.gui then return end

    local scale = self:cl_parseScale(text)

    if scale then
        self.network:sendToServer("sv_updateSettings", { shaftScale = scale })
        self.gui:setText("ShaftScaleInput", string.format("%g", scale))
    else
        local current = (self.currentSettings and self.currentSettings.shaftScale) or ShaftController.DEFAULT_SHAFT_SCALE
        self.gui:setText("ShaftScaleInput", string.format("%g", current))
    end

    self.pendingShaftScale = nil
end


function ShaftController:cl_onColorChanged(_, text)
    self.pendingColor = text
end


function ShaftController:cl_onJointScaleChanged(_, text)
    self.pendingJointScale = text
end


function ShaftController:cl_onShaftScaleChanged(_, text)
    self.pendingShaftScale = text
end


function ShaftController:cl_parseColor(text)
    if not text then return nil end
    local hex = text:gsub("#", ""):gsub(" ", ""):upper()
    if #hex < 6 then return nil end

    local r = tonumber(hex:sub(1, 2), 16)
    local g = tonumber(hex:sub(3, 4), 16)
    local b = tonumber(hex:sub(5, 6), 16)
    if not (r and g and b) then return nil end

    return sm.color.new(r / 255, g / 255, b / 255)
end


function ShaftController:cl_parseScale(text)
    if not text then return nil end
    local scale = tonumber(text)
    if not scale then return nil end
    return math.max(0.25, math.min(5.0, scale))
end


function ShaftController:cl_onGuiClose()
    local newSettings = {}
    local hasChanges = false

    if self.pendingColor then
        local color = self:cl_parseColor(self.pendingColor)
        if color then
            newSettings.color = color
            hasChanges = true
        end
    end

    if self.pendingJointScale then
        local scale = self:cl_parseScale(self.pendingJointScale)
        if scale then
            newSettings.jointScale = scale
            hasChanges = true
        end
    end

    if self.pendingShaftScale then
        local scale = self:cl_parseScale(self.pendingShaftScale)
        if scale then
            newSettings.shaftScale = scale
            hasChanges = true
        end
    end

    if hasChanges then
        self.network:sendToServer("sv_updateSettings", newSettings)
    end

    self.pendingColor = nil
    self.pendingJointScale = nil
    self.pendingShaftScale = nil
end
