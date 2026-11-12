-- Harness for the mod's Journal.lua (the "Archipelago" Codex chapter).
--
-- Loads the installed game's real CodexData.lua, CodexLogic.lua and CodexPresentation.lua with
-- the engine stubbed, loads the mod's Journal.lua on top with its real wraps, and drives the book
-- the way the game does: open it, switch chapters, hover entries, scroll, close. Checks that the
-- chapter is listed, that every page's title and body reach the book's own text boxes, that the
-- vanilla chapters still work, and that pages arriving while the book is open are handled.
--
-- What it cannot check is how any of it looks.
--
-- Usage: lua journal_harness.lua <Journal.lua> <payload file>
--   payload file: one JOURNAL payload (tools/journal_check.py --sample writes one).

local SCRIPTS = [[C:\Program Files (x86)\Steam\steamapps\common\Hades II\Content\Scripts\]]
local MOD_FILE = assert(arg[1], "pass the path to Journal.lua")
local PAYLOAD_FILE = assert(arg[2], "pass a file holding a JOURNAL payload")

local failures = 0
local function check(cond, what)
  if not cond then
    failures = failures + 1
    print("  FAIL: " .. what)
  end
end

-- ---- permissive engine: any global the scripts name that isn't defined below is a no-op -------
local STUB
STUB = setmetatable({}, {
  __index = function() return STUB end,
  __call = function() return STUB end,
  __concat = function() return "" end,
  __newindex = function() end,
  __len = function() return 0 end,
  __add = function() return 0 end, __sub = function() return 0 end,
  __mul = function() return 0 end, __div = function() return 0 end,
  __unm = function() return 0 end,
})
local NILS = { verboseLogging = true, CodexStatus = true, Journal = true }
setmetatable(_G, { __index = function(_, k)
  if NILS[k] then return nil end
  return STUB
end })

-- ---- the parts of the engine the Codex code needs to behave for real ------------------------
local next_id = 100
local boxes = {}        -- component id -> { Text = last text set }
local destroyed = {}
function CreateScreenComponent(args)
  next_id = next_id + 1
  return { Id = next_id, Name = args and args.Name }
end
local function set_text(args)
  if args and args.Id and args.Text ~= nil then
    boxes[args.Id] = boxes[args.Id] or {}
    boxes[args.Id].Text = args.Text
  end
end
function CreateTextBox(args) set_text(args) end
function ModifyTextBox(args) set_text(args) end
function Destroy(args)
  if args and args.Id then destroyed[args.Id] = true end
  for _, id in ipairs((args and args.Ids) or {}) do destroyed[id] = true end
end
function IsEmpty(t)
  if t == nil then return true end
  return next(t) == nil
end
function TableLength(t)
  local n = 0
  for _ in pairs(t or {}) do n = n + 1 end
  return n
end
function ShallowCopyTable(t)
  local out = {}
  for k, v in pairs(t or {}) do out[k] = v end
  return out
end
function DeepCopyTable(t)
  if type(t) ~= "table" or t == STUB then return t end
  local out = {}
  for k, v in pairs(t) do out[k] = DeepCopyTable(v) end
  return out
end
function OverwriteTableKeys(dst, src)
  for k, v in pairs(src or {}) do dst[k] = v end
  return dst
end
function Contains(t, value)
  for _, v in pairs(t or {}) do
    if v == value then return true end
  end
  return false
end
function GetKey(t, value)
  for k, v in pairs(t or {}) do
    if v == value then return k end
  end
  return nil
end
function GetAllIds(components)
  local ids = {}
  for _, c in pairs(components or {}) do
    if type(c) == "table" and c.Id then ids[#ids + 1] = c.Id end
  end
  return ids
end
function ApplyLocalizedProperties(t) return t end
function GetDisplayName(args) return (args and args.Text) or "" end
function GetLanguage() return "en" end
-- Vanilla entries: listed when they have no requirements at all (the real rule for an empty
-- table) or the one requirement a new save already meets (Melinoe's own entry: completed runs
-- >= 0); everything gated on play history counts as locked. `nothing_unlocked` locks even that.
nothing_unlocked = false
function IsGameStateEligible(_, requirements)
  if IsEmpty(requirements) then return true end
  if nothing_unlocked then return false end
  local first = requirements[1]
  return #requirements == 1 and type(first) == "table" and first.Comparison == ">=" and first.Value == 0
end
function CallFunctionName(name, ...) return _G[name](...) end
function thread(fn, ...) return fn(...) end
function wait() end
function OnControlPressed() end
function DebugAssert() end
function DebugPrint() end
function CheckCooldown() return false end
function SetThreadWait() return false end
function AreScreensActive() return next(ActiveScreens) ~= nil end
function IsInputAllowed() return true end
function IsCombatEncounterActive() return false end
function IsAggroedUnitBlockingInteract() return false end
function IsScreenOpen(name) return ActiveScreens[name] ~= nil end
function OnScreenOpened(screen) ActiveScreens[screen.Name] = screen end
function OnScreenCloseFinished(screen) ActiveScreens[screen.Name] = nil end
function CreateScreenFromData(screen, componentData)
  local function make(name, data)
    if type(data) ~= "table" or data == STUB then return end
    if data.FunctionName ~= nil then
      CallFunctionName(data.FunctionName, screen, data)
    else
      local component = CreateScreenComponent({ Name = name })
      component.Screen = screen
      screen.Components[name] = component
      for childName, child in pairs(data.Children or {}) do make(childName, child) end
    end
  end
  for name, data in pairs(componentData) do
    if name ~= "Order" then make(name, data) end
  end
end

ScreenData, ActiveScreens, NarrativeData, EnemyData = {}, {}, {}, {}
GameState = { CodexEntriesViewed = {}, ScreensViewed = {}, WorldUpgradesAdded = {}, EnemyKills = {} }
SessionState, SessionMapState, MapState = {}, {}, {}
RequiredKillEnemies = {}
CurrentRun = { Hero = { UntargetableFlags = {} }, CurrentRoom = {} }

local function load_game(name)
  local f = assert(io.open(SCRIPTS .. name, "rb"))
  local src = f:read("a"); f:close()
  src = src:gsub("^\239\187\191", "")
  assert(load(src, "@" .. name))()
end
load_game("CodexData.lua")
load_game("CodexLogic.lua")
load_game("CodexPresentation.lua")
ScreenData.Codex.Name = "Codex"
ScreenData.BoonInfo = { TraitDictionary = {} }

-- ---- the mod's environment --------------------------------------------------------------
local logged = {}
rom = { log = { info = function(m) logged[#logged + 1] = m end, warning = function(m) logged[#logged + 1] = m end } }
-- The mod's texture package (the tab's Archipelago logo): present unless has_package is cleared.
local has_package, loaded_packages = true, {}
rom.path = {
  combine = function(a, b) return a .. "/" .. b end,
  exists = function() return has_package end,
}
_PLUGIN = { plugins_data_mod_folder_path = "plugins_data/mod" }
function SetupMap() end
function LoadPackages(args) loaded_packages[#loaded_packages + 1] = args.Name end
game = _G
local try_failures = {}
function AP_try(label, fn)
  local ok, err = pcall(fn)
  if not ok then try_failures[#try_failures + 1] = label .. ": " .. tostring(err) end
  return ok, err
end
modutil = { mod = { Path = { Wrap = function(name, fn)
  local base = rawget(_G, name)
  assert(type(base) == "function", "wrap target isn't a real function: " .. name)
  _G[name] = function(...) return fn(base, ...) end
end } } }

assert(loadfile(MOD_FILE))()
local CHAPTER = Journal.CHAPTER

local function read_payload()
  local f = assert(io.open(PAYLOAD_FILE, "rb"))
  local text = f:read("a"); f:close()
  return (text:gsub("[\r\n]+$", ""))
end
local payload = read_payload()

local function open_book()
  OpenCodexScreen()
  return ActiveScreens.Codex
end
local function text_of(component) return component and boxes[component.Id] and boxes[component.Id].Text end
local function open_chapter(screen, name)
  CodexOpenChapter(screen, screen.Components[name], {})
end

-- ---- 1. boot: wraps, Codex switched on, placeholder chapter --------------------------------
print("1. boot")
local vanillaChapters = #CodexOrdering.Order
local vanillaTabs = #ScreenData.Codex.Tabs
Journal.install_wraps()
check(vanillaChapters == 8 and vanillaTabs == 8, "vanilla book should have 8 chapters and 8 tabs")
CodexInit()
check(CodexStatus and CodexStatus.Enabled == true, "CodexInit should leave the Codex enabled")
check(Contains(CodexOrdering.Order, CHAPTER), "chapter missing from CodexOrdering.Order")
check(#CodexOrdering.Order == 9 and #ScreenData.Codex.Tabs == 9, "expected 9 chapters and 9 tabs")
check(ScreenData.Codex.ChapterSpacingX == 84 and ScreenData.Codex.ChapterX == 405, "9-tab row numbers")
check(#CodexOrdering[CHAPTER] == 1, "before any JOURNAL the chapter should hold the one waiting page")
CodexInit(); Journal.enable(); Journal.install()
check(CodexData[CHAPTER].Icon == "BrittisH39-Hades2RogueArchipelago\\APLogo", "tab icon should be the packaged logo")
check(#loaded_packages == 0, "enable() must not load packages (it also runs outside a map)")
SetupMap()
check(loaded_packages[1] == "plugins_data/mod/BrittisH39-Hades2RogueArchipelago", "SetupMap should load the mod's package")
has_package = false
Journal.enable(); SetupMap()
check(CodexData[CHAPTER].Icon == "GUI\\Screens\\Inventory\\Icon-Inventory" and #loaded_packages == 1,
  "without the package file: vanilla stand-in icon, nothing loaded")
has_package = true
Journal.enable()
check(#CodexOrdering.Order == 9 and #ScreenData.Codex.Tabs == 9, "install must be idempotent")
check(HasUnlockedEntries(CHAPTER), "HasUnlockedEntries should list the chapter")

-- The end-of-encounter pass the game runs over every Codex entry (RoomLogic.lua).
for chapterName, chapterData in pairs(CodexData) do
  for entryName in pairs(chapterData.Entries) do
    CheckCodexUnlock(chapterName, entryName, { DeferShowUpdate = true, SkipEntriesUnlockedCacheUpdate = true })
  end
end
CalcNumCodexEntriesUnlocked()

-- ---- 2. the book with no client: waiting page ---------------------------------------------
print("2. waiting page")
-- No vanilla chapter has an entry: vanilla OpenCodexScreen would index a missing tab.
nothing_unlocked = true
local screen = open_book()
check(screen ~= nil and CodexStatus.SelectedChapterName == CHAPTER,
  "with no vanilla chapter unlocked the book should open on this chapter")
check(text_of(screen.Components.EntryText) == "Waiting for the Archipelago client.", "waiting page (empty book)")
CloseCodexScreen(screen)
nothing_unlocked = false
CodexStatus.SelectedChapterName = ScreenData.Codex.DefaultChapter
screen = open_book()
check(screen ~= nil, "OpenCodexScreen didn't open the screen")
check(screen.Components[CHAPTER] ~= nil, "no tab button for the chapter")
check(screen.Components["CategoryIcon" .. CHAPTER] ~= nil, "no tab icon for the chapter")
open_chapter(screen, CHAPTER)
check(CodexStatus.SelectedChapterName == CHAPTER, "chapter didn't open")
check(text_of(screen.Components.EntryText) == "Waiting for the Archipelago client.", "waiting page body not shown")
check(text_of(screen.Components.CategoryTitleText) == Journal.title, "chapter title not shown")
CloseCodexScreen(screen)
check(ActiveScreens.Codex == nil, "screen didn't close")

-- ---- 3. real pages ------------------------------------------------------------------------
print("3. pages from the client")
Journal.receive(payload)
local title, pages = Journal.parse(payload)
check(#pages > 0, "payload has no pages")
check(#CodexOrdering[CHAPTER] == #pages, "chapter should list every page")
check(Journal.title == title, "chapter title should come from the payload")
screen = open_book()
check(CodexStatus.SelectedChapterName == CHAPTER and screen.OpenEntryName ~= nil,
  "the book should reopen on the chapter it was closed on")
local shownEntries = 0
for i, page in ipairs(pages) do
  local key = "AP_Page_" .. page.key
  local button = screen.Components[key]
  check(button ~= nil, "no entry button for page " .. page.key)
  if button then
    shownEntries = shownEntries + 1
    check(text_of(button) == page.title, "entry label for " .. page.key .. " is '" .. tostring(text_of(button)) .. "'")
    MouseOverCodexEntry(button)
    check(text_of(screen.Components.EntryText) == page.body, "body of " .. page.key .. " not shown")
    check(text_of(screen.Components.EntryTitle) == page.title, "title of " .. page.key .. " not shown")
    check(button.Portrait ~= nil and button.Portrait ~= "", "page " .. page.key .. " has no portrait")
  end
end
check(screen.NumItems == #pages, "screen.NumItems should equal the page count")
if #pages > screen.MaxVisibleEntries then
  CodexScrollDown(screen, screen.Components.ScrollDown)
  check(screen.ScrollOffset == screen.MaxVisibleEntries, "scroll down didn't page")
  local first = pages[screen.MaxVisibleEntries + 1]
  check(text_of(screen.Components.EntryText) == first.body, "scrolling down should open the next page's first entry")
  CodexScrollUp(screen, screen.Components.ScrollUp)
  check(screen.ScrollOffset == 0, "scroll up didn't page back")
end

-- ---- 4. vanilla chapters are untouched ----------------------------------------------------
print("4. vanilla chapters")
open_chapter(screen, "ChthonicGods")
check(CodexStatus.SelectedChapterName == "ChthonicGods", "couldn't switch to a vanilla chapter")
check(screen.Components["AP_Page_" .. pages[1].key] == nil, "our entry buttons should be gone after leaving the chapter")
local vanillaText = text_of(screen.Components.EntryText)
check(vanillaText ~= nil and vanillaText ~= pages[1].body, "vanilla entry text was overwritten")
CodexPrevChapter(screen); CodexNextChapter(screen)
open_chapter(screen, CHAPTER)

-- ---- 5. updates while the book is open ----------------------------------------------------
print("5. live updates")
local openKey = screen.OpenEntryName
local changed
do
  -- same page keys, every title and body replaced
  local records = {}
  for record in (payload .. "|"):gmatch("(.-)|") do records[#records + 1] = record end
  for i = 2, #records do
    local key, ptitle, portrait = records[i]:match("^(.-)~(.-)~(.-)~")
    records[i] = key .. "~" .. ptitle .. "!~" .. portrait .. "~NEW " .. key
  end
  changed = table.concat(records, "|")
end
Journal.receive(changed)
local openPage = screen.Components[openKey].EntryData.AP_Page
check(text_of(screen.Components.EntryText) == "NEW " .. openPage.key, "open page didn't redraw on a same-pages update")
check(text_of(screen.Components[openKey]) == openPage.title and openPage.title:sub(-1) == "!", "entry labels didn't refresh")
check(Journal.pending == nil, "a same-pages update shouldn't be held back")
-- a different page set has to wait for the book to close
Journal.receive(title .. "|solo~Solo~~only page")
check(Journal.pending ~= nil, "a different page set should wait while the book is open")
check(#CodexOrdering[CHAPTER] == #pages, "chapter was rebuilt under the open book")
MouseOverCodexEntry(screen.Components[openKey])
CloseCodexScreen(screen)
screen = open_book()
check(Journal.pending == nil and #CodexOrdering[CHAPTER] == 1, "held pages weren't applied on reopen")
check(text_of(screen.Components.EntryText) == "only page", "the reopened book should show the new single page")
check(screen.Components["AP_Page_solo"] and text_of(screen.Components["AP_Page_solo"]) == "Solo", "new page's label")
CloseCodexScreen(screen)

-- ---- 6. ten tabs (Zagreus' Journey adds its own chapter) ----------------------------------
print("6. ten tabs")
CodexData.ZJ_Fake = { TitleText = "ZJ", Icon = "x", Entries = { ZJ_Entry = { Entries = {}, Image = "x" } } }
CodexOrdering.ZJ_Fake = { "ZJ_Entry" }
table.insert(CodexOrdering.Order, "ZJ_Fake")
Journal.receive(payload)
check(#CodexOrdering.Order == 10 and #ScreenData.Codex.Tabs == 10, "expected 10 chapters and 10 tabs")
check(ScreenData.Codex.ChapterSpacingX == 72, "10-tab row should use the tighter spacing")
check(ScreenData.Codex.Tabs[9].X == -10 and ScreenData.Codex.Tabs[10].X == 14, "tab 9/10 X positions")
screen = open_book()
check(screen.Components.ZJ_Fake ~= nil and screen.Components[CHAPTER] ~= nil, "both extra chapters need a tab")
open_chapter(screen, "ZJ_Fake")
open_chapter(screen, CHAPTER)
check(text_of(screen.Components.EntryText) ~= nil, "chapter didn't draw with ten tabs")
CloseCodexScreen(screen)

for _, failure in ipairs(try_failures) do
  failures = failures + 1
  print("  FAIL (error inside a wrap): " .. failure)
end
if failures > 0 then
  print(failures .. " failure(s)")
  os.exit(1)
end
print("journal_harness: all checks passed (" .. shownEntries .. " pages driven through the real Codex code)")
