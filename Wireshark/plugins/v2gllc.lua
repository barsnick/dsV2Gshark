--
-- Copyright 2024, dSPACE GmbH. All rights reserved.
--
-- This dissector adds functionality to the standard HomePlug AV dissector
-- to allow displaying CP State indication packets
--
-- See license file (dsV2Gshark_LICENSE.txt)
--
local HPAV_PACKET_SIZE = 60
local HPAV_ETHERNET_TYPE = 0x88e1

local v2gcommon = require("v2gcommon")

p_hpav_llc = Proto("homeplug-llc", "HomePlug AV protocol LLC diagnostics")
local p_hpav_llc_info = {
    version = v2gcommon.DS_V2GSHARK_VERSION,
    author = "dSPACE GmbH",
    repository = "https://github.com/dspace-group/dsV2Gshark"
}
set_plugin_info(p_hpav_llc_info)

local f_freq = ProtoField.int16("homeplug-av-llc.freq", "Frequency", base.DEC)
local f_dutycycle = ProtoField.float("homeplug-av-llc.dutycycle", "Duty cycle", base.DEC)
local f_voltage = ProtoField.float("homeplug-av-llc.voltage", "Voltage", base.DEC)
local f_cpstate = ProtoField.int8("homeplug-av-llc.cpstate", "CP State")
local f_acmax = ProtoField.string("homeplug-av-llc.ac_max", "AC max current")
local f_result = ProtoField.string("homeplug-av-llc.result", "Result")

p_hpav_llc.fields = {f_freq, f_dutycycle, f_voltage, f_cpstate, f_acmax, f_result}

local function extract_infos_spidcom(buf)
    local freq = buf(9, 2):le_int()
    local dutycycle = buf(11, 2):le_int() / 10
    local voltage = buf(13, 2):le_int() / 1000
    local result = buf(8, 1):int()
    return freq, dutycycle, voltage, result
end

local function extract_infos_iotecha(buf)
    local freq = buf(15, 2):le_int()
    local dutycycle = buf(14, 1):le_int()
    local voltage = buf(17, 2):le_int() / 1000
    return freq, dutycycle, voltage, -1
end

local function get_ac_max_current(dutycycle)
    if dutycycle < 8 then
        return -1
    elseif dutycycle < 10 then
        return 6
    elseif dutycycle < 85 then
        return dutycycle * 0.6
    elseif dutycycle < 96 then
        return (dutycycle - 64) * 2.5
    elseif dutycycle < 97 then
        return 80
    else
        return -1
    end
end

local function get_cp_state(freq, dutycycle, voltage)
    local StateA = 12
    local StateB = 9
    local StateC = 6
    local StateD = 3
    local StateEF = 0
    local Tolerance = 1

    if (dutycycle == 0 or dutycycle == 100) and freq > 0 then
        return "-"
    end

    local cp_state_out
    if voltage <= (StateA + Tolerance) and voltage >= (StateA - Tolerance) then
        cp_state_out = "A"
    elseif voltage <= (StateB + Tolerance) and voltage >= (StateB - Tolerance) then
        cp_state_out = "B"
    elseif voltage <= (StateC + Tolerance) and voltage >= (StateC - Tolerance) then
        cp_state_out = "C"
    elseif voltage <= (StateD + Tolerance) and voltage >= (StateD - Tolerance) then
        cp_state_out = "D"
    elseif voltage <= (StateEF + Tolerance) then
        return "E/F"
    else
        return "-"
    end

    local pwm_active = dutycycle > 0 and dutycycle < 100 and freq > 950 and freq < 1050
    if pwm_active then
        return cp_state_out .. "2"
    else
        return cp_state_out .. "1"
    end
end

local function cp_state_to_int(cp_state)
    --- used for I/O Graph plotting of CP State
    if cp_state == "A1" then
        return 1
    elseif cp_state == "A2" then
        return 2
    elseif cp_state == "B1" then
        return 3
    elseif cp_state == "B2" then
        return 4
    elseif cp_state == "C1" then
        return 5
    elseif cp_state == "C2" then
        return 6
    elseif cp_state == "D1" then
        return 7
    elseif cp_state == "D2" then
        return 8
    elseif cp_state == "E/F" then
        return -1
    end
    return 0
end

local function is_spidcom_cp_packet(buf)
    -- packet format by SPIDCOM Technologies SA
    local mac_mme_type = buf(1, 2):le_uint()
    local mme_vendor = buf(5, 3):uint()
    return mme_vendor == 0x0013D7 and mac_mme_type == 0xA10E
end

local function is_iotecha_cp_packet(buf)
    -- packet format by ST/IoTecha
    local mac_mme_type = buf(1, 2):le_uint()
    local mme_vendor = buf(5, 3):uint()
    return mme_vendor == 0x0080E1 and mac_mme_type == 0xA22E
end

local function dissect_hpav_llc(buf, pinfo, root)
    -- check hpav message type
    local freq, dutycycle, voltage, result
    if is_spidcom_cp_packet(buf) then
        freq, dutycycle, voltage, result = extract_infos_spidcom(buf)
    elseif is_iotecha_cp_packet(buf) then
        freq, dutycycle, voltage, result = extract_infos_iotecha(buf)
    else
        return 0
    end

    pinfo.cols.protocol = "HomePlug AV LLC"
    local subtree = root:add(p_hpav_llc, buf(0))

    local elem_frequency = subtree:add(f_freq, freq)
    elem_frequency:append_text("Hz")
    -- frequency bitmask: 001
    if result == 1 or result == 3 or result == 5 or result == 7 then
        elem_frequency:append_text(" (changed)")
    end

    local elem_dutycycle = subtree:add(f_dutycycle, dutycycle)
    elem_dutycycle:append_text("%")
    -- duty cycle bitmask: 010
    if result == 2 or result == 3 or result == 6 or result == 7 then
        elem_dutycycle:append_text(" (changed)")
    end

    local elem_voltage = subtree:add(f_voltage, voltage)
    elem_voltage:append_text("V")
    -- voltage bitmask: 100
    if result == 4 or result == 5 or result == 6 or result == 7 then
        elem_voltage:append_text(" (changed)")
    end

    local cp_state = get_cp_state(freq, dutycycle, voltage)
    subtree:add(f_cpstate, cp_state_to_int(cp_state)):set_text("CP State: " .. cp_state) -- store as int to allow plotting

    local ac_max_current = get_ac_max_current(dutycycle)
    if ac_max_current ~= -1 then
        subtree:add(f_acmax, ac_max_current):append_text("A")
        pinfo.cols.info = "CP State: " .. cp_state .. " [AC max current: " .. ac_max_current .. "A]"
    else
        pinfo.cols.info = "CP State: " .. cp_state
    end
    return HPAV_PACKET_SIZE
end

function p_hpav_llc.dissector(buf, pinfo, root)
    local processed_data = 0

    -- call default hpav dissector to add additional information
    local hpav_dissector = Dissector.get("homeplug-av")
    if hpav_dissector ~= nil then
        processed_data = hpav_dissector:call(buf, pinfo, root)
    end

    return processed_data + dissect_hpav_llc(buf, pinfo, root)
end

local heuristic_hpav_dissector = function(buf, pinfo, root)
    -- heuristic dissector on ethernet level. We need to check
    -- whether this is a correct HPAV LLC packet or not

    -- check size
    if buf:len() ~= HPAV_PACKET_SIZE then
        return 0
    end

    -- check eth type
    if buf(12, 2):uint() ~= HPAV_ETHERNET_TYPE then
        return 0
    end

    buf = buf(14):tvb() -- skip eth header

    if not is_iotecha_cp_packet(buf) and not is_spidcom_cp_packet(buf) then
        -- this will trigger default dissection (eth + hpav)
        return 0
    end

    -- fake Eth layer
    eth_tree = root:add(
        "Ethernet II,",
        "Src: " .. tostring(pinfo.src) .. ", Dst: " .. tostring(pinfo.dst)
    )
	eth_tree:add("Destination:", tostring(pinfo.dst))
	eth_tree:add("Source:", tostring(pinfo.src))
	eth_tree:add("Type:", "Homeplug AV (0x88e1)")
    eth_tree:add("[ Note:", "Default Ethernet dissection skipped for this packet! For more details, update to Wireshark 4.x or deactivate homeplug-llc (Ctrl+Shift+E) ]")

    return dissect_hpav_llc(buf, pinfo, root)
end

if v2gcommon.check_version("4.0.0") then
    DissectorTable.get("ethertype"):add(0x88e1, p_hpav_llc)
else
    -- Use heuristic dissector for old wireshark versions.
    -- Otherwise, the HPAV dissector for non-LLC packets is overridden.
    p_hpav_llc:register_heuristic("eth", heuristic_hpav_dissector)
end
