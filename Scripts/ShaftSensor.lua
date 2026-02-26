------------------
-- ShaftSensor
-- 传动轴速度传感器
------------------

ShaftSensor = class()

ShaftSensor.connectionOutput = sm.interactable.connectionType.logic
ShaftSensor.maxParentCount = 0
ShaftSensor.maxChildCount = 255

ShaftSensor.colorHighlight = sm.color.new("#2ED8B8")
ShaftSensor.colorNormal = sm.color.new("#1ABC9C")

ShaftSensor.SENSOR_UUID = sm.uuid.new("d5a0f003-0003-4d53-8003-000000000003")

-- 设置参数的范围限制
ShaftSensor.RATIO_MIN = -10.0
ShaftSensor.RATIO_MAX = 10.0
ShaftSensor.RATIO_DEFAULT = 1.0


---- 服务端 ----

function ShaftSensor:server_onCreate()
    local S = ShaftSensor
    self.setting = self.storage:load()

    if not self.setting then
        self.setting = {
            reverse = false,
            ratio = S.RATIO_DEFAULT
        }
    end

    -- 兼容旧存档：填充缺失字段
    if self.setting.reverse == nil then
        self.setting.reverse = false
    end
    if self.setting.ratio == nil then
        self.setting.ratio = S.RATIO_DEFAULT
    end

    self:sv_applyPublicData()
    self.network:setClientData({ setting = self.setting })
end


function ShaftSensor:sv_applyPublicData()
    self.interactable:setPublicData({
        reverse = self.setting.reverse,
        ratio = self.setting.ratio
    })
end


function ShaftSensor:sv_updateSettings(newSettings)
    local S = ShaftSensor

    if newSettings.reverse ~= nil and type(newSettings.reverse) == "boolean" then
        self.setting.reverse = newSettings.reverse
    end

    if newSettings.ratio ~= nil and type(newSettings.ratio) == "number" then
        self.setting.ratio = math.max(S.RATIO_MIN, math.min(S.RATIO_MAX, newSettings.ratio))
    end

    self.storage:save(self.setting)
    self:sv_applyPublicData()
    self.network:setClientData({ setting = self.setting })
end


---- 客户端 ----

function ShaftSensor:client_onCreate()
    local S = ShaftSensor

    self.currentSettings = {
        reverse = false,
        ratio = S.RATIO_DEFAULT
    }

    self.currentLang = nil
    self.langText = nil
    self:cl_loadLanguage()

    self.gui = nil
    self:cl_initGui()
end


function ShaftSensor:cl_loadLanguage(language)
    local lang = language or sm.gui.getCurrentLanguage()
    local newLang = (lang == "Chinese") and "Chinese" or "English"

    if newLang == self.currentLang then
        return
    end

    self.currentLang = newLang
    self.langText = sm.json.open("$MOD_DATA/Gui/Language/" .. newLang .. "/ShaftSensor.json")
end


function ShaftSensor:client_onLanguageChange(language)
    self:cl_loadLanguage(language)
    self:cl_applyLanguageToGui()
end


function ShaftSensor:cl_applyLanguageToGui()
    if not self.gui or not self.langText then return end
    self.gui:setText("guiTitle", self.langText.guiTitle or "#ffcc00Sensor Settings")
    self.gui:setText("ReverseLabel", self.langText.reverseLabel or "#ffffffReverse Output:")
    self.gui:setText("ReverseOff", self.langText.reverseOff or "Off")
    self.gui:setText("ReverseOn", self.langText.reverseOn or "On")
    self.gui:setText("RatioLabel", self.langText.ratioLabel or "#ffffffOutput Ratio:")
    self.gui:setText("RatioUnit", "#888888" .. (self.langText.ratioUnit or "x"))
end


function ShaftSensor:client_onDestroy()
    if self.gui then
        if self.gui:isActive() then
            self.gui:close()
        end
        self.gui:destroy()
        self.gui = nil
    end
end


function ShaftSensor:client_onClientDataUpdate(data)
    if data.setting then
        self.currentSettings = data.setting
    end

    if self.gui and self.gui:isActive() then
        self:cl_updateGuiDisplay()
    end
end


function ShaftSensor:cl_initGui()
    self.gui = sm.gui.createGuiFromLayout("$MOD_DATA/Gui/Layouts/ShaftSensor.layout")
    self.gui:setButtonCallback("ReverseOn", "cl_onReverseButtonClicked")
    self.gui:setButtonCallback("ReverseOff", "cl_onReverseButtonClicked")
    self.gui:setTextAcceptedCallback("RatioInput", "cl_onRatioAccepted")
    self.gui:setTextChangedCallback("RatioInput", "cl_onRatioChanged")
    self.gui:setOnCloseCallback("cl_onGuiClose")

    self.pendingRatio = nil
end


function ShaftSensor:cl_updateGuiDisplay()
    if not self.gui or not self.currentSettings then return end

    local isReversed = self.currentSettings.reverse or false
    self.gui:setButtonState("ReverseOn", isReversed)
    self.gui:setButtonState("ReverseOff", not isReversed)

    local ratio = self.currentSettings.ratio or ShaftSensor.RATIO_DEFAULT
    self.gui:setText("RatioInput", string.format("%g", ratio))
end


function ShaftSensor:client_onInteract(_, state)
    if state and self.gui then
        self:cl_loadLanguage()
        self:cl_applyLanguageToGui()
        self:cl_updateGuiDisplay()
        self.gui:open()
        self.pendingRatio = nil
    end
end


function ShaftSensor:client_canInteract()
    local text = (self.langText and self.langText.interactionText) or "Sensor Settings"
    sm.gui.setInteractionText("", sm.gui.getKeyBinding("Use", true), " " .. text)
    return true
end


function ShaftSensor:cl_onReverseButtonClicked(buttonName)
    if not self.gui then return end

    local newReverse = (buttonName == "ReverseOn")
    self.network:sendToServer("sv_updateSettings", { reverse = newReverse })
end


function ShaftSensor:cl_onRatioAccepted(_, text)
    if not self.gui then return end

    local ratio = self:cl_parseRatio(text)

    if ratio then
        self.network:sendToServer("sv_updateSettings", { ratio = ratio })
        self.gui:setText("RatioInput", string.format("%g", ratio))
    else
        local current = (self.currentSettings and self.currentSettings.ratio) or ShaftSensor.RATIO_DEFAULT
        self.gui:setText("RatioInput", string.format("%g", current))
    end

    self.pendingRatio = nil
end


function ShaftSensor:cl_onRatioChanged(_, text)
    self.pendingRatio = text
end


function ShaftSensor:cl_parseRatio(text)
    if not text then return nil end
    local ratio = tonumber(text)
    if not ratio then return nil end
    local S = ShaftSensor
    return math.max(S.RATIO_MIN, math.min(S.RATIO_MAX, ratio))
end


function ShaftSensor:cl_onGuiClose()
    if self.pendingRatio then
        local ratio = self:cl_parseRatio(self.pendingRatio)
        if ratio then
            self.network:sendToServer("sv_updateSettings", { ratio = ratio })
        end
    end

    self.pendingRatio = nil
end
