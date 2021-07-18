--
-- callng:kami.lua
-- 
-- The Initial Developer of the Original Code is
-- Minh Minh <hnimminh at[@] outlook dot[.] com>
-- Portions created by the Initial Developer are Copyright (C) the Initial Developer. 
-- All Rights Reserved.
-- ------------------------------------------------------------------------------------------------------------------------------------------------
--
-- KSR - the object exporting Kamailio KEMI functions (app_lua module)
-- sr - the old object exporting Kamailio functions (app_lua_sr module)
--
-- Relevant Remarks:
--  * do not execute Lua 'exit' - that will kill Lua interpreter which is embedded in Kamailio, resulting in killing Kamailio
--  * use KSR.x.exit() to trigger the stop of executing the script
--  * KSR.drop() is only marking the SIP message for drop, but doesn't stop the execution of the script. Use KSR.x.exit() after it or KSR.x.drop()
--
-- ------------------------------------------------------------------------------------------------------------------------------------------------

require("callng.utilities")

-- global variables corresponding to defined values (e.g., flags) in kamailio.cfg
FLT_NATS=5
FLB_NATB=6
FLB_NATSIPPING=7

B2BUA_IP = '10.104.0.2'
PROXY_IP = '10.104.0.2'

-- SIP request routing
-- equivalent of request_route{}
function ksr_request_route()
	-- debug log test
	delogify('module', 'callng', 'space', 'kami', 'action', 'new-request', 'ru', KSR.pv.get("$ru"))

	-- per request initial checks
	sanitize()

	-- connection keepalive response
	if KSR.is_OPTIONS() then
		keepalive()
	end

	-- NAT detection and fix
	nathandle()

	-- CANCEL processing
	if KSR.is_CANCEL() then
		if KSR.tm.t_check_trans()>0 then
			ksr_route_relay()
		end
		return 1
	end

	-- handle requests within SIP dialogs
	withindlg()

	-- only initial requests (no To tag)
	-- handle retransmissions
	if KSR.tmx.t_precheck_trans()>0 then
		KSR.tm.t_check_trans()
		return 1
	end
	if KSR.tm.t_check_trans()==0 then 
		return 1 
	end

	-- record routing for dialog forming requests (in case they are routed)
	-- remove preloaded route headers
	KSR.hdr.remove("Route")
	if KSR.is_method_in("IS") then
		KSR.rr.record_route()
	end

	-- registrar service with user authentication
	if KSR.is_REGISTER() then
		registrar()
	end

	-- incoming call
	if KSR.is_INVITE() then
		local srcip = KSR.pv.get('$si')
		if srcip == B2BUA_IP then 
			call_from_switch()
		else
			call_from_public()
		end
	end

	if KSR.corex.has_ruri_user() < 0 then
		-- request with no Username in RURI
		KSR.sl.sl_send_reply(484,"Address Incomplete")
		return 1
	end

	return 1
end


-- ---------------------------------------------------------------------------------------------------------------------------------
--  initial security checks and policy
-- ---------------------------------------------------------------------------------------------------------------------------------
function sanitize()
	-- rate limiting anti-flooding attached, optimize them later
	if not KSR.is_myself_srcip() then
		local srcip = KSR.kx.get_srcip()
		if KSR.htable.sht_match_name("ipban", "eq", srcip) > 0 then
			-- ip is already blocked
			delogify('module', 'callng', 'space', 'kami', 'action', 'blocked', 'method', KSR.kx.get_method(), 'fromuri', KSR.kx.get_furi(), 'srcip', srcip, 'srcport', KSR.kx.get_srcport())
			KSR.x.exit()
		end
		if KSR.pike.pike_check_req() < 0 then
			delogify('module', 'callng', 'space', 'kami', 'action', 'pike', 'method', KSR.kx.get_method(), 'fromuri', KSR.kx.get_furi(), 'srcip', srcip, 'srcport', KSR.kx.get_srcport())
			KSR.htable.sht_seti("ipban", srcip, 1)
			KSR.x.exit()
		end
	end

	-- blacked list user agent (hack, pentest, ddos)
	local ua = KSR.kx.gete_ua()
	if string.find(ua, "friendly")
		or string.find(ua, "sipsak")
		or string.find(ua, "siparmyknife")
		or string.find(ua, "VaxIPUserAgent")
		or string.find(ua, "VaxSIPUserAgent")
		or string.find(ua, "scanner")
		or string.find(ua, "sipcli")
		or string.find(ua, "sipvicious") then
		KSR.drop()
		KSR.x.exit()
	end

	if KSR.kx.get_msglen()>4096 then
		KSR.sl.sl_send_reply(513,"Message Too Large")
		KSR.x.exit()
	end

	if KSR.maxfwd.process_maxfwd(10)<0 then
		KSR.sl.sl_send_reply(483,"Too Many Hops")
		KSR.x.exit()
	end

	if KSR.sanity.sanity_check(1511, 7)<0 then
		delogify('module', 'callng', 'space', 'kami', 'action', 'malformed', 'srcip', srcip, 'srcport', KSR.kx.get_srcport())
		KSR.x.exit()
	end

	-- Do not support yet these method {M:MESSAGE, N:NOTIFY, P:PUBLISH, F:REFER, S:SUBSCRIBE}
	-- file the feature request if you wish them to be supported
    if KSR.is_method_in("MNPFS") then
		KSR.sl.sl_send_reply("405", "Method Not Allowed")
		KSR.x.exit()
	end

end

-- ---------------------------------------------------------------------------------------------------------------------------------
-- Keepalive Repsonse for OPTION
-- ---------------------------------------------------------------------------------------------------------------------------------
function keepalive()
	if KSR.is_myself_ruri() and KSR.corex.has_ruri_user()<0 then
		KSR.sl.sl_send_reply(200, "Keepalive")
		KSR.x.exit()
	end
end

-- ---------------------------------------------------------------------------------------------------------------------------------
-- Originator NAT Detection and Fix
-- ---------------------------------------------------------------------------------------------------------------------------------
function nathandle()
	KSR.force_rport()
	if KSR.nathelper.nat_uac_test(23)>0 then
		if KSR.is_REGISTER() then
			KSR.nathelper.fix_nated_register()
		elseif KSR.siputils.is_first_hop()>0 then
			KSR.nathelper.set_contact_alias()
		end
		KSR.setflag(FLT_NATS)
	end
	return 1
end

-- ---------------------------------------------------------------------------------------------------------------------------------
-- wrapper around tm relay function
-- ---------------------------------------------------------------------------------------------------------------------------------
function ksr_route_relay()
	-- enable additional event routes for forwarded requests
	-- - serial forking, RTP relaying handling, a.s.o.
	if KSR.is_method_in("IBSU") then
		if KSR.tm.t_is_set("branch_route")<0 then
			KSR.tm.t_on_branch("ksr_branch_manage")
		end
	end
	if KSR.is_method_in("ISU") then
		if KSR.tm.t_is_set("onreply_route")<0 then
			KSR.tm.t_on_reply("ksr_onreply_manage")
		end
	end

	if KSR.is_INVITE() then
		if KSR.tm.t_is_set("failure_route")<0 then
			KSR.tm.t_on_failure("ksr_failure_manage")
		end
	end

	if KSR.tm.t_relay()<0 then
		KSR.sl.sl_reply_error()
	end
	KSR.x.exit()
end


-- ---------------------------------------------------------------------------------------------------------------------------------
-- Handle requests within SIP dialogs
-- ---------------------------------------------------------------------------------------------------------------------------------
function withindlg()
	if KSR.siputils.has_totag()<0 then 
		return 1
	end

	-- sequential request withing a dialog should
	-- take the path determined by record-routing
	if KSR.rr.loose_route()>0 then
		ksr_route_dlguri()
		if KSR.is_ACK() then
			-- ACK is forwarded statelessly
			ksr_route_natmanage()
		elseif KSR.is_NOTIFY() then
			-- Add Record-Route for in-dialog NOTIFY as per RFC 6665.
			KSR.rr.record_route()
		end
		ksr_route_relay()
		KSR.x.exit()
	end
	if KSR.is_ACK() then
		if KSR.tm.t_check_trans() >0 then
			-- no loose-route, but stateful ACK
			-- must be an ACK after a 487
			-- or e.g. 404 from upstream server
			ksr_route_relay()
			KSR.x.exit()
		else
			-- ACK without matching transaction ... ignore and discard
			KSR.x.exit()
		end
	end
	KSR.sl.sl_send_reply(404, "Not Here")
	KSR.x.exit()
end

-- ---------------------------------------------------------------------------------------------------------------------------------
-- registrar service with user authentication
-- ---------------------------------------------------------------------------------------------------------------------------------
function registrar()
	delogify('module', 'callng', 'space', 'kami', 'action', 'register', 'fhost', KSR.kx.gete_fhost(), 'fd', KSR.kx.get_fhost(), 'au', KSR.kx.gete_au(), 'cid', KSR.kx.get_callid())
	-- authenticate requests
	-- local auth_check = KSR.auth_db.auth_check(KSR.kx.gete_fhost(), "subscriber", 1)
	local auth_check = KSR.auth.pv_auth_check(KSR.kx.gete_fhost(), '7d807e02493dfd0a8113a8b2f7540f3f', 1, 0)
	delogify('module', 'callng', 'space', 'kami', 'action', 'register', 'fhost', KSR.kx.gete_fhost(), 'fd', KSR.kx.get_fhost(), 'au', KSR.kx.gete_au(), 'cid', KSR.kx.get_callid(), 'auth_check', auth_check)
	if auth_check<0 then
		KSR.auth.auth_challenge(KSR.kx.gete_fhost(), 0)
		delogify('module', 'callng', 'space', 'kami', 'action', 'register3')
		KSR.x.exit()
	end

	delogify('module', 'callng', 'space', 'kami', 'action', 'register4', 'status', 'authenticated')

	if KSR.isflagset(FLT_NATS) then
		KSR.setbflag(FLB_NATB)
		-- do SIP NAT pinging
		KSR.setbflag(FLB_NATSIPPING)
	end
	
	local aorsaved = KSR.registrar.save("libreusrloc", "5", "sip:minh@libre.sbc")
	delogify('module', 'callng', 'space', 'kami', 'action', 'register5', 'aorsaved', aorsaved)
	if aorsaved < 0 then
		KSR.sl.sl_reply_error()
	end

	-- user authenticated - remove auth header
	KSR.auth.consume_credentials()
	-- done process
	KSR.x.exit()
end


function call_from_public()
	delogify('module', 'callng', 'space', 'kami', 'action', 'public-invite-1', 'fhost', KSR.kx.gete_fhost(), 'fd', KSR.kx.get_fhost(), 'au', KSR.kx.gete_au(), 'cid', KSR.kx.get_callid())
	-- authenticate requests
	-- local auth_check = KSR.auth_db.auth_check(KSR.kx.gete_fhost(), "subscriber", 1)
	local auth_check = KSR.auth.pv_auth_check(KSR.kx.gete_fhost(), '7d807e02493dfd0a8113a8b2f7540f3f', 1, 0)
	delogify('module', 'callng', 'space', 'kami', 'action', 'public-invite-2', 'fhost', KSR.kx.gete_fhost(), 'fd', KSR.kx.get_fhost(), 'au', KSR.kx.gete_au(), 'cid', KSR.kx.get_callid(), 'auth_check', auth_check)
	if auth_check<0 then
		KSR.auth.auth_challenge(KSR.kx.gete_fhost(), 0)
		delogify('module', 'callng', 'space', 'kami', 'action', 'public-invite-3')
		KSR.x.exit()
	end

	KSR.auth.consume_credentials()
	delogify('module', 'callng', 'space', 'kami', 'action', 'public-invite-4', 'status', 'authenticated')

	KSR.pv.sets('$du', 'sip:'..B2BUA_IP..':5080;transport=udp')
	KSR.pv.sets('$fs', 'udp:'..PROXY_IP..':5060')
	ksr_route_relay()
end

function call_from_switch()
	delogify('module', 'callng', 'space', 'kami', 'action', 'switch-invite-1', 'fhost', KSR.kx.gete_fhost(), 'fd', KSR.kx.get_fhost(), 'au', KSR.kx.gete_au(), 'cid', KSR.kx.get_callid())
	local rc = KSR.registrar.lookup("libreusrloc")
	delogify('module', 'callng', 'space', 'kami', 'action', 'public-invite-2', 'localtion', rc)
	if rc<0 then
		KSR.tm.t_newtran()
		if rc==-1 or rc==-3 then
			KSR.sl.send_reply(404, "Not Found")
			KSR.x.exit()
		elseif rc==-2 then
			KSR.sl.send_reply(405, "Method Not Allowed")
			KSR.x.exit()
		end
	end
	ksr_route_relay()
	KSR.x.exit()
end

-- RTPProxy control
function ksr_route_natmanage()
	if not KSR.rtpproxy then
		delogify('module', 'callng', 'space', 'kami', 'action', 'natmanage', 'return', 'do-nothing')
		return 1
	end
	if KSR.siputils.is_request()>0 then
		if KSR.siputils.has_totag()>0 then
			if KSR.rr.check_route_param("nat=yes")>0 then
				KSR.setbflag(FLB_NATB)
			end
		end
	end
	if (not (KSR.isflagset(FLT_NATS) or KSR.isbflagset(FLB_NATB))) then
		return 1
	end

	KSR.rtpproxy.rtpproxy_manage("co")

	if KSR.siputils.is_request()>0 then
		if KSR.siputils.has_totag()<0 then
			if KSR.tmx.t_is_branch_route()>0 then
				KSR.rr.add_rr_param(";nat=yes")
			end
		end
	end
	if KSR.siputils.is_reply()>0 then
		if KSR.isbflagset(FLB_NATB) then
			KSR.nathelper.set_contact_alias()
		end
	end
	return 1
end

-- URI update for dialog requests
function ksr_route_dlguri()
	if not KSR.isdsturiset() then
		KSR.nathelper.handle_ruri_alias()
	end
	return 1
end

-- Routing to foreign domains
function ksr_route_sipout()
	if KSR.is_myself_ruri() then return 1; end

	KSR.hdr.append("P-Hint: outbound\r\n")
	ksr_route_relay()
	KSR.x.exit()
end

-- Manage outgoing branches
-- equivalent of branch_route[...]{}
function ksr_branch_manage()
	delogify('module', 'callng', 'space', 'kami', 'action', 'new-branch', 'branch', KSR.pv.get("$T_branch_idx"), 'ruri', KSR.kx.get_ruri())
	ksr_route_natmanage()
	return 1
end

-- Manage incoming replies
-- equivalent of onreply_route[...]{}
function ksr_onreply_manage()
	delogify('module', 'callng', 'space', 'kami', 'action', 'incoming-reply')
	local scode = KSR.kx.get_status()
	if scode>100 and scode<299 then
		ksr_route_natmanage()
	end
	return 1
end

-- Manage failure routing cases
-- equivalent of failure_route[...]{}
function ksr_failure_manage()
	ksr_route_natmanage()

	if KSR.tm.t_is_canceled()>0 then
		return 1
	end
	return 1
end

-- SIP response handling
-- equivalent of reply_route{}
function ksr_reply_route()
	delogify('module', 'callng', 'space', 'kami', 'action', 'response')
	return 1
end
