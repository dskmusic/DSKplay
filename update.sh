#!/bin/bash

# Read the version and build number from pubspec.yaml
version=$(grep version pubspec.yaml | awk -F'[ +]' '{print $2}' | tr -d "'")
build=$(grep version pubspec.yaml | awk -F'[ +]' '{print $3}' | tr -d "'")

# Define the variable names and file name
variable="appVersion"
buildVariable="appBuildNumber"
filename="lib/constants/version.dart"

# Write the version and build number to the Dart file
cat > $filename <<EOF
const $variable = '$version';
const $buildVariable = '$build';
EOF
