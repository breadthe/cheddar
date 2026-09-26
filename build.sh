#!/bin/bash

# chmod +x ./build.sh

# if not installed
# brew install xcodegen

xcodegen generate

xcodebuild -scheme Cheddar -configuration Release -derivedDataPath build build

# run these only on 1st install
# sudo xcodebuild -license accept
# xcodebuild -runFirstLaunch

# install
ditto build/Build/Products/Release/Cheddar.app /Applications/Cheddar.app
