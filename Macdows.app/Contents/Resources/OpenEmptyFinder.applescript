-- Finder terminology in raw Apple event codes, usable during headless builds.
set finderID to "com.apple.finder"
tell application id finderID
    if not («class pisf» of it) then return
    repeat with candidate in (get every «class cwin»)
        if (class of candidate) is «class brow» then return
    end repeat
    «event corecrel» given «class kocl»:«class brow»
end tell
