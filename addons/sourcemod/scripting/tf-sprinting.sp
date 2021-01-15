/*
 * Copyright (C) 2020  Mikusch
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with this program.  If not, see <https://www.gnu.org/licenses/>.
 */

#include <sourcemod>
#include <sdkhooks>
#include <dhooks>

#pragma semicolon 1
#pragma newdecls required

#define SOUND_SPRINT_START	"player/suit_sprint.wav"

ConVar tf_sprint_enabled;
ConVar tf_sprint_speedmultiplier;
ConVar sv_stickysprint;

Handle g_SDKCallSetSpeed;

bool g_IsAutoSprinting[MAXPLAYERS + 1];
float g_AutoSprintMinTime[MAXPLAYERS + 1];
bool g_IsSprinting[MAXPLAYERS + 1];

public Plugin myinfo = 
{
	name = "TF2 Sprinting", 
	author = "Mikusch", 
	description = "Allows players to sprint using +speed", 
	version = "1.0.1", 
	url = "https://github.com/Mikusch/tf-sprinting"
}

public void OnPluginStart()
{
	tf_sprint_enabled = CreateConVar("tf_sprint_enabled", "1", "Enable players to sprint using +speed", _, true, 0.0, true, 1.0);
	tf_sprint_enabled.AddChangeHook(ConVarChanged_EnableSprint);
	
	tf_sprint_speedmultiplier = CreateConVar("tf_sprint_speedmultiplier", "1.59375", "Multiplier to base speed while sprinting", _, true, 0.0);
	sv_stickysprint = CreateConVar("sv_stickysprint", "0", _, _, true, 0.0, true, 1.0);
	
	GameData gamedata = new GameData("tf-sprinting");
	if (gamedata == null)
	{
		SetFailState("Could not find tf-sprinting gamedata");
	}
	
	DynamicDetour detour = DynamicDetour.FromConf(gamedata, "CTFPlayer::TeamFortress_CalculateMaxSpeed");
	if (detour)
	{
		detour.Enable(Hook_Post, DHookCallback_TeamFortress_CalculateMaxSpeed_Post);
	}
	else
	{
		SetFailState("Failed to create detour setup handle for function CTFPlayer::TeamFortress_CalculateMaxSpeed");
	}
	
	StartPrepSDKCall(SDKCall_Entity);
	PrepSDKCall_SetFromConf(gamedata, SDKConf_Signature, "CTFPlayer::TeamFortress_SetSpeed");
	g_SDKCallSetSpeed = EndPrepSDKCall();
	if (!g_SDKCallSetSpeed)
	{
		SetFailState("Failed to create SDKCall for function CTFPlayer::TeamFortress_SetSpeed");
	}
	
	delete gamedata;
	
	for (int client = 1; client <= MaxClients; client++)
	{
		if (IsClientInGame(client))
		{
			OnClientPutInServer(client);
		}
	}
}

public void OnMapStart()
{
	PrecacheSound(SOUND_SPRINT_START);
}

public void OnClientPutInServer(int client)
{
	SDKHook(client, SDKHook_PreThink, SDKHookCB_ClientPreThink);
}

public void ConVarChanged_EnableSprint(ConVar convar, const char[] oldValue, const char[] newValue)
{
	if (!convar.BoolValue)
	{
		for (int client = 1; client <= MaxClients; client++)
		{
			if (IsSprinting(client))
			{
				StopSprinting(client);
			}
		}
	}
}

public MRESReturn DHookCallback_TeamFortress_CalculateMaxSpeed_Post(int client, DHookReturn ret)
{
	if (IsSprinting(client))
	{
		float speed = ret.Value;
		speed *= tf_sprint_speedmultiplier.FloatValue;
		ret.Value = speed;
		return MRES_Supercede;
	}
	
	return MRES_Ignored;
}

public void SDKHookCB_ClientPreThink(int client)
{
	// If we're dead, we can't sprint
	if (!IsPlayerAlive(client))
	{
		StopSprinting(client);
		return;
	}
	
	HandleSpeedChanges(client);
	
	if (sv_stickysprint.BoolValue && g_IsAutoSprinting[client])
	{
		int buttons = GetClientButtons(client);
		
		// If we're ducked and not in the air
		if (GetEntProp(client, Prop_Data, "m_bDucked") && GetEntPropEnt(client, Prop_Data, "m_hGroundEntity") != -1)
		{
			StopSprinting(client);
		}
		// Stop sprinting if the player lets off the stick for a moment.
		else if (!(buttons & IN_FORWARD || buttons & IN_BACK || buttons & IN_MOVELEFT || buttons & IN_MOVERIGHT))
		{
			if (GetGameTime() > g_AutoSprintMinTime[client])
			{
				StopSprinting(client);
			}
		}
		else
		{
			// Stop sprinting one half second after the player stops inputting with the move stick.
			g_AutoSprintMinTime[client] = GetGameTime() + 0.5;
		}
	}
	else if (IsSprinting(client))
	{
		// Disable sprint while ducked unless we're in the air (jumping)
		if (GetEntProp(client, Prop_Data, "m_bDucked") && (GetEntPropEnt(client, Prop_Data, "m_hGroundEntity") != -1))
		{
			StopSprinting(client);
		}
	}
}

void TeamFortress_SetSpeed(int client)
{
	if (g_SDKCallSetSpeed)
	{
		SDKCall(g_SDKCallSetSpeed, client);
	}
}

void HandleSpeedChanges(int client)
{
	int buttonsChanged = GetEntProp(client, Prop_Data, "m_afButtonPressed") | GetEntProp(client, Prop_Data, "m_afButtonReleased");
	
	bool canSprint = CanSprint(client);
	bool isSprinting = IsSprinting(client);
	bool wantSprint = (canSprint && (GetEntProp(client, Prop_Data, "m_nButtons") & IN_SPEED));
	if (isSprinting != wantSprint && (buttonsChanged & IN_SPEED))
	{
		// If someone wants to sprint, make sure they've pressed the button to do so.
		if (wantSprint)
		{
			if (sv_stickysprint.BoolValue)
			{
				StartAutoSprint(client);
			}
			else
			{
				StartSprinting(client);
			}
		}
		else
		{
			if (!sv_stickysprint.BoolValue)
			{
				StopSprinting(client);
			}
			
			// Reset key, so it will be activated post whatever is suppressing it.
			SetEntProp(client, Prop_Data, "m_nButtons", GetEntProp(client, Prop_Data, "m_nButtons") & ~IN_SPEED);
		}
	}
}

bool CanSprint(int client)
{
	return (tf_sprint_enabled.BoolValue && !(GetEntProp(client, Prop_Data, "m_bDucked") && !GetEntProp(client, Prop_Data, "m_bDucking")) && GetEntProp(client, Prop_Data, "m_nWaterLevel") != 3);
}

bool IsSprinting(int client)
{
	return g_IsSprinting[client];
}

void StartAutoSprint(int client)
{
	if (IsSprinting(client))
	{
		StopSprinting(client);
	}
	else
	{
		StartSprinting(client);
		g_IsAutoSprinting[client] = true;
		g_AutoSprintMinTime[client] = GetGameTime() + 1.5;
	}
}

void StartSprinting(int client)
{
	EmitSoundToClient(client, SOUND_SPRINT_START, _, SNDCHAN_VOICE, SNDLEVEL_DRYER, _, 0.9);
	
	g_IsSprinting[client] = true;
	
	TeamFortress_SetSpeed(client);
}

void StopSprinting(int client)
{
	g_IsSprinting[client] = false;
	
	TeamFortress_SetSpeed(client);
	
	if (sv_stickysprint.BoolValue)
	{
		g_IsAutoSprinting[client] = false;
		g_AutoSprintMinTime[client] = 0.0;
	}
}
