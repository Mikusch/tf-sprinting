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
#include <tf2_stocks>
#include <sdkhooks>
#include <dhooks>

#pragma semicolon 1
#pragma newdecls required

#define SOUND_SPRINT_START		"player/suit_sprint.wav"

public Plugin myinfo = 
{
	name = "TF2 Sprinting", 
	author = "Mikusch", 
	description = "Allows players to sprint using +speed, just like in Half-Life 2", 
	version = "v1.0", 
	url = "https://github.com/Mikusch/tf-sprinting"
}

ConVar tf_sprint_enabled;
ConVar tf_sprint_speedmultiplier;
ConVar sv_stickysprint;

bool g_IsAutoSprinting[MAXPLAYERS + 1];
float g_AutoSprintMinTime[MAXPLAYERS + 1];
bool g_IsSprinting[MAXPLAYERS + 1];

public void OnPluginStart()
{
	tf_sprint_enabled = CreateConVar("tf_sprint_enabled", "1", "Whether you are allowed to sprint", _, true, 0.0, true, 1.0);
	tf_sprint_enabled.AddChangeHook(ConVarChanged_SprintEnabled);
	
	tf_sprint_speedmultiplier = CreateConVar("tf_sprint_speedmultiplier", "0.59375", "Speed multiplier when a player is holding down the sprint key", _, true, 0.0);
	sv_stickysprint = CreateConVar("sv_stickysprint", "0");
	
	GameData gamedata = new GameData("tf-sprinting");
	if (gamedata == null)
	{
		SetFailState("Could not find tf-sprinting gamedata");
	}
	//TODO: Actually change the max speed based on g_IsSprinting in a TeamFortress_SetSpeed detour
	delete gamedata;
	
	for (int client = 1; client <= MaxClients; client++)
	{
		if (IsClientInGame(client))
		{
			OnClientPutInServer(client);
		}
	}
}

public void OnClientPutInServer(int client)
{
	SDKHook(client, SDKHook_PreThink, SDKHookCB_ClientPreThink);
}

public void ConVarChanged_SprintEnabled(ConVar convar, const char[] oldValue, const char[] newValue)
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

public void SDKHookCB_ClientPreThink(int client)
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
	
	if (sv_stickysprint.BoolValue && g_IsAutoSprinting[client])
	{
		// If we're ducked and not in the air
		if (GetEntProp(client, Prop_Data, "m_bDucked") && GetEntPropEnt(client, Prop_Data, "m_hGroundEntity") != -1)
		{
			StopSprinting(client);
		}
		else
		{
			float controlStick[3];
			controlStick[0] = GetEntPropFloat(client, Prop_Data, "m_flForwardMove");
			controlStick[1] = GetEntPropFloat(client, Prop_Data, "m_flSideMove");
			
			// Stop sprinting if the player lets off the stick for a moment.
			if (GetVectorLength(controlStick) == 0.0)
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
}

void StopSprinting(int client)
{
	g_IsSprinting[client] = false;
	
	if (sv_stickysprint.BoolValue)
	{
		g_IsAutoSprinting[client] = false;
		g_AutoSprintMinTime[client] = 0.0;
	}
}
