# Hades 2 Archipelago

Hades 2 implementation for the Archipelago Multiworld Randomizer - Created by BrittisH39 with AI assistance.



Works on Windows. Linux and Steam Deck work through Proton. Steam Deck guide: https://sgg-modding.github.io/Hades2ModWiki/docs/installing-mods/steam-deck

The mod, the apworld, and the host's apworld must all be the version the seed was generated with. The client now shows an error box naming all three when they don't match.



## **Setup**

#### 

#### **Mod**

* Install [r2modman](https://thunderstore.io/c/riskofrain2/p/ebkr/r2modman/)
* Launch, then find and select Hades 2. Select which store you own Hades 2 on (Epic Games Launcher untested at this time)
* Select or create a profile.
* Select online on the left side, and search and find "Hades2RogueArchipelago"
* Select download, then Download with Dependencies
* Zagreus Journey is no longer a dependency, so it won't be downloaded automatically. If you want the Hades 1 content, search for and download "Zagreus Journey" by NikkelM on the same profile. It only works if you have Hades 1 installed.



#### **APWorld/Hades 2 Client**

* Download `Hades2Rogue.apworld` from the [latest release](https://github.com/BrittisH39/Hades2Archipelago/releases/latest)
* Download and install [Archipelago](https://archipelago.gg/tutorial/Archipelago/setup_en) if you haven't already
* Archipelago 0.6.7 or newer, from the [latest release](https://github.com/ArchipelagoMW/Archipelago/releases/latest) (not from the bottom of the releases page)



Install the apworld one way, not both. Two copies is a known cause of checks not sending. When updating, replace the old file. The host needs the same apworld.

**Then EITHER**

* Open the Archipelago Launcher
* Click and drag the Hades2Rogue.apworld file onto the Archipelago Window
* It will give you a confirmation message, relaunch Archipelago, and you're done.

**OR**

* Open you Archipelago installation
* Find the "Custom\_worlds" folder
* Place the Hades2Rogue.apworld file into that folder



#### **Connecting**

* Search for the Hades 2 Rogue Client in the archipelago launcher
* Launch, connect to a server, select your slot.
* Launch the game with mods from r2modman
* Start a NEW SAVE
* You should be good to go!



#### **Troubleshooting**

"Items arrive but checks don't send" is almost always a version mismatch. The client's error box names the mod, apworld and seed versions so you can see which one doesn't match.

Mod log: r2modman profile folder → `ReturnOfModding\LogOutput.log`. It resets on every game start, earlier ones are in `ReturnOfModding\backup\<date>_LogOutput.log`. Client log: `<Archipelago folder>\logs\Hades2RogueClient_<date>.txt` (default `C:\ProgramData\Archipelago\logs`).

Downpatching: the mod's Thunderstore page → Versions tab → install an older one. Older apworlds are on the [GitHub releases list](https://github.com/BrittisH39/Hades2Archipelago/releases).



# **Notes**



I consider this to be stable, but you will still likely run into a few bugs or issues. Please let me know if you do. Additionally I would love to hear any thoughts or ideas you have; the [Discord](https://discord.com/channels/731205301247803413/1375345291926044722) is the best way to share those.

Zagreus Journey is no longer a dependency for the mod. If you still have it downloaded from an older version and you don't have Hades 1, it will pop-up and tell you it's not installed correctly. As long as you turned off (Or left off) Zagreus Journey in the YAML, you can ignore this.

