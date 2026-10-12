# Run from project root directory

xcodegen generate
xcodebuild -project MacDown.xcodeproj -scheme MacDown -configuration Release \
    -derivedDataPath build/local build

osascript -e 'quit app "MacDown"'
ditto build/local/Build/Products/Release/MacDown.app /Applications/MacDown.app

LS=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
$LS -u "$PWD/build/local/Build/Products/Release/MacDown.app"
$LS -f /Applications/MacDown.app
rm -rf build/local