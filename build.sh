#!/bin/bash

# chmod +x ./build.sh

# run these only on 1st install, before anything else
# sudo xcode-select -s /Applications/Xcode.app/Contents/Developer
# sudo xcodebuild -license accept
# xcodebuild -runFirstLaunch

# if not installed
# brew install xcodegen

xcodegen generate

xcodebuild -scheme Cheddar -configuration Release -derivedDataPath build build

# install
ditto build/Build/Products/Release/Cheddar.app /Applications/Cheddar.app
