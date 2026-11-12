---@diagnostic disable: lowercase-global
-- Journal.lua — the in-game tracker: an "Archipelago" chapter in the Codex (Book of Shadows).
--
-- The Python client builds every page as finished text in the game's own markup and sends them
-- in one JOURNAL line (Journal.py / PROTOCOL.md); this file only puts them in the book. The Codex
-- is plain Lua data -- CodexOrdering.Order lists the chapters, CodexOrdering[chapter] the entry
-- keys, CodexData[chapter].Entries[key] each entry, ScreenData.Codex.Tabs one tab per chapter --
-- so a chapter is added by filling those four tables, and the pages are drawn by setting the
-- book's own text boxes after the vanilla functions have run (the wraps at the bottom).
--
-- tools/journal_harness.lua drives this file through the game's real CodexLogic.lua /
-- CodexData.lua with the engine stubbed; what it can't show is how the tab row and the page text
-- actually look.

Journal = Journal or {}
Journal.pages = Journal.pages or {}       -- { key, title, portrait, body } in page order
Journal.pending = Journal.pending or nil  -- pages that arrived while the book was open on a different page set

local CHAPTER = "AP_Tracker"
local ENTRY_PREFIX = "AP_Page_"           -- entry keys are global to the whole Codex; never reuse a vanilla one
Journal.CHAPTER = CHAPTER

-- Shown only until the client's first JOURNAL line arrives, which carries the real chapter title
-- and pages. Wording chosen by the project owner on 2026-10-04; don't reword without asking.
Journal.title = Journal.title or "Archipelago"
local WAITING_PAGE = {
  key = "waiting",
  title = "Not Connected",
  portrait = "",
  body = "Waiting for the Archipelago client.",
}

-- Tab icon: the Archipelago logo, from the mod's own texture package in plugins_data
-- (tools/build_mod_package.py: 72x72, the size of the vanilla GUI\Screens\Codex\Icon-* art, so
-- the vanilla icon scale fits it). PACKAGE is both the package's file name and the prefix of the
-- texture names inside it. An install without the package keeps the vanilla stand-in.
-- TAB_ICON_SCALE, when set, replaces ScreenData.Codex.CategoryIconScale for this tab only.
local PACKAGE = "BrittisH39-Hades2RogueArchipelago"
local PACKAGE_ICON = PACKAGE .. "\\APLogo"
local FALLBACK_ICON = "GUI\\Screens\\Inventory\\Icon-Inventory"
Journal.TAB_ICON = Journal.TAB_ICON or FALLBACK_ICON
Journal.TAB_ICON_SCALE = nil
local DEFAULT_PORTRAIT = "Codex_Portrait_BiomeCrossroads"

-- Tab row. Vanilla has 8 tabs. Zagreus' Journey adds a ninth and squeezes the row to keep it on
-- the book (its Scripts/CodexData.lua: ChapterX 405, ChapterSpacingX 84, CategoryIconOffsetX -2,
-- new tab at X -10); the same numbers are used here when this chapter is the ninth. Ten tabs
-- (both mods) need a tighter row still, which nobody has tuned by eye yet.
local TAB_CHAPTER_X = 405
local TAB_SPACING = { [9] = 84, [10] = 72 }
local TAB_SPACING_MIN = 64
local TAB_ICON_OFFSET_X = -2
local TAB_FIRST_EXTRA_X = -10             -- X of tab 9
local TAB_EXTRA_STEP_X = 24               -- each tab after it
local TAB_Y = -88

local function log_info(msg) rom.log.info("[AP] " .. msg) end

local function split(text, sep)
  local out, from = {}, 1
  while true do
    local at = string.find(text, sep, from, true)
    if not at then
      out[#out + 1] = string.sub(text, from)
      return out
    end
    out[#out + 1] = string.sub(text, from, at - 1)
    from = at + 1
  end
end

-- "<chapter title>|<key>~<title>~<portrait>~<body>|..." -> title, pages
function Journal.parse(payload)
  local records = split(payload or "", "|")
  local title = records[1]
  local pages, seen = {}, {}
  for i = 2, #records do
    local f = split(records[i], "~")
    local key = f[1]
    if key and key ~= "" and not seen[key] then
      seen[key] = true
      pages[#pages + 1] = { key = key, title = f[2] or key, portrait = f[3] or "", body = f[4] or "" }
    end
  end
  return title, pages
end

local function shown_pages()
  if #Journal.pages > 0 then return Journal.pages end
  return { WAITING_PAGE }
end

local function contains(list, value)
  for _, v in ipairs(list) do
    if v == value then return true end
  end
  return false
end

local function layout_tabs(codex, chapterCount)
  if chapterCount < 9 then return end
  for i = 9, chapterCount do
    local tab = codex.Tabs[i]
    if not tab then
      local art = ((i - 1) % 3) + 1
      tab = {
        Y = TAB_Y,
        Animation = "GUI\\Screens\\Codex\\CategoryTab" .. art,
        Highlight = "GUI\\Screens\\Codex\\CategoryTabHighlight" .. art,
        Active = "GUI\\Screens\\Codex\\CategoryTabActiveHighlightOverlay" .. art,
      }
      codex.Tabs[i] = tab
    end
    tab.X = TAB_FIRST_EXTRA_X + (i - 9) * TAB_EXTRA_STEP_X
  end
  codex.ChapterX = TAB_CHAPTER_X
  codex.ChapterSpacingX = TAB_SPACING[chapterCount] or TAB_SPACING_MIN
  codex.CategoryIconOffsetX = TAB_ICON_OFFSET_X
end

-- (Re)build the chapter from Journal.pages. Safe to call any number of times, and it has to be:
-- the mod reloads on every save load, and another mod may add its own chapter after this ran.
-- Never call while the book is open on this chapter with a different page set -- its entry
-- buttons point at the tables replaced here (Journal.receive holds such an update back).
function Journal.install()
  local data, ordering, screens = game.CodexData, game.CodexOrdering, game.ScreenData
  if not (data and ordering and ordering.Order and screens and screens.Codex and screens.Codex.Tabs) then
    return false
  end
  local entries, order = {}, {}
  for _, page in ipairs(shown_pages()) do
    local key = ENTRY_PREFIX .. page.key
    entries[key] = {
      -- An empty Entries list (not nil): several vanilla loops ipairs() it.
      Entries = {},
      Image = (page.portrait ~= "" and page.portrait) or DEFAULT_PORTRAIT,
      AP_Page = page,
    }
    order[#order + 1] = key
  end
  data[CHAPTER] = { TitleText = Journal.title, Icon = Journal.TAB_ICON, Entries = entries }
  ordering[CHAPTER] = order
  if not contains(ordering.Order, CHAPTER) then
    table.insert(ordering.Order, CHAPTER)
  end
  layout_tabs(screens.Codex, #ordering.Order)
  return true
end

local function package_path()
  local folder = _PLUGIN and _PLUGIN.plugins_data_mod_folder_path
  if not folder then return nil end
  local path = rom.path.combine(folder, PACKAGE)
  if rom.path.exists(path .. ".pkg") then return path end
  return nil
end

-- Pick the tab icon, and with load = true load the package that holds it. The engine drops
-- packages on every map change, so this runs at each SetupMap and again as the book opens.
function Journal.load_art(load)
  local path = package_path()
  Journal.TAB_ICON = path and PACKAGE_ICON or FALLBACK_ICON
  if path and load and game.LoadPackages then game.LoadPackages({ Name = path }) end
end

-- The Codex is switched off on a new save until Hecate's first-fight dialogue runs EnableCodex
-- (EnemyData_Hecate.lua), which a Surface-, Nightmare- or Dream-start seed may never reach.
function Journal.enable()
  if game.CodexStatus then game.CodexStatus.Enabled = true end
  Journal.load_art(false)
  Journal.install()
end

local function open_screen()
  local screens = game.ActiveScreens
  return screens and screens.Codex or nil
end

local function same_keys(pages)
  local current = shown_pages()
  if #current ~= #pages then return false end
  for i, page in ipairs(pages) do
    if current[i].key ~= page.key then return false end
  end
  return true
end

local function page_of(button)
  if not button or button.ChapterName ~= CHAPTER then return nil end
  return button.EntryData and button.EntryData.AP_Page
end

-- Entry buttons are created with their KEY as text (CodexOpenChapter: Text = entryName, a text
-- id lookup). Give each its page title instead.
function Journal.label_entries(screen)
  local chapter = game.CodexData and game.CodexData[CHAPTER]
  if not (chapter and screen and screen.Components) then return end
  for key, entry in pairs(chapter.Entries) do
    local component = screen.Components[key]
    if component and component.Id and entry.AP_Page then
      game.ModifyTextBox({ Id = component.Id, Text = entry.AP_Page.title })
    end
  end
end

-- The same two text boxes CodexOpenEntry fills for a vanilla entry.
function Journal.render(screen, button)
  local page = page_of(button)
  if not (page and screen and screen.Components) then return end
  local text, title = screen.Components.EntryText, screen.Components.EntryTitle
  if text and text.Id then
    game.ModifyTextBox({ Id = text.Id, Text = (page.body ~= "" and page.body) or " " })
    game.SetAlpha({ Id = text.Id, Fraction = 1, Duration = 0.12, EaseIn = 0, EaseOut = 1 })
  end
  if title and title.Id then
    game.ModifyTextBox({ Id = title.Id, Text = page.title })
    game.SetAlpha({ Id = title.Id, Fraction = 1, Duration = 0.12, EaseIn = 0, EaseOut = 1 })
  end
end

local function apply(title, pages)
  if title and title ~= "" then Journal.title = title end
  Journal.pages = pages
  Journal.pending = nil
  Journal.install()
end

-- JOURNAL handler. With the book closed the chapter is simply rebuilt. With it open: the same
-- set of pages is refreshed in place (the open page redraws), a different set waits for the book
-- to close.
function Journal.receive(payload)
  local title, pages = Journal.parse(payload)
  local screen = open_screen()
  if not screen then
    apply(title, pages)
    return
  end
  local chapter = game.CodexData and game.CodexData[CHAPTER]
  if not (chapter and same_keys(pages)) then
    Journal.pending = { title = title, pages = pages }
    return
  end
  Journal.pages = pages
  for _, page in ipairs(pages) do
    local entry = chapter.Entries[ENTRY_PREFIX .. page.key]
    if entry then entry.AP_Page = page end
  end
  if game.CodexStatus and game.CodexStatus.SelectedChapterName == CHAPTER then
    Journal.label_entries(screen)
    local open = screen.OpenEntryName and screen.Components and screen.Components[screen.OpenEntryName]
    Journal.render(screen, open)
  end
end

function Journal.before_open()
  Journal.load_art(true)
  if Journal.pending then
    apply(Journal.pending.title, Journal.pending.pages)
  else
    Journal.install()
  end
  -- OpenCodexScreen opens the remembered chapter, else the default one (ChthonicGods), and
  -- indexes that chapter's tab without checking it exists. Vanilla can rely on the default
  -- chapter always having an entry by the time the Codex is enabled; with the Codex forced on
  -- from the first room, don't: fall back to this chapter, which always has a page.
  local status, data = game.CodexStatus, game.CodexData
  if status and data and game.HasUnlockedEntries then
    local function has_tab(name) return name ~= nil and data[name] ~= nil and game.HasUnlockedEntries(name) end
    if not has_tab(status.SelectedChapterName) and not has_tab(game.ScreenData.Codex.DefaultChapter) then
      status.SelectedChapterName = CHAPTER
    end
  end
end

function Journal.after_chapters(screen)
  if not (Journal.TAB_ICON_SCALE and screen and screen.Components) then return end
  local icon = screen.Components["CategoryIcon" .. CHAPTER]
  if icon and icon.Id then
    game.SetScale({ Id = icon.Id, Fraction = Journal.TAB_ICON_SCALE })
  end
end

function Journal.after_open_chapter(screen, button)
  if button and button.ChapterName == CHAPTER then Journal.label_entries(screen) end
end

-- Wraps on the vanilla Codex functions. Each runs the original untouched and then adds to it, and
-- none of the additions can break the book: a failure is logged once (AP_try) and the vanilla
-- result stands.
function Journal.install_wraps()
  modutil.mod.Path.Wrap("CodexInit", function(base, ...)
    base(...)
    AP_try("Journal.enable", Journal.enable)
  end)
  modutil.mod.Path.Wrap("SetupMap", function(base, ...)
    AP_try("Journal.load_art", function() Journal.load_art(true) end)
    return base(...)
  end)
  modutil.mod.Path.Wrap("OpenCodexScreen", function(base, ...)
    AP_try("Journal.before_open", Journal.before_open)
    return base(...)
  end)
  modutil.mod.Path.Wrap("CodexScreenCreateChapters", function(base, screen, ...)
    base(screen, ...)
    AP_try("Journal.after_chapters", function() Journal.after_chapters(screen) end)
  end)
  modutil.mod.Path.Wrap("CodexOpenChapter", function(base, screen, button, args)
    base(screen, button, args)
    AP_try("Journal.after_open_chapter", function() Journal.after_open_chapter(screen, button) end)
  end)
  modutil.mod.Path.Wrap("CodexOpenEntry", function(base, screen, button, args)
    base(screen, button, args)
    AP_try("Journal.render", function() Journal.render(screen, button) end)
  end)
  log_info("in-game tracker: Codex chapter hooks installed")
end
