#!/bin/bash
tail -n +954 Sources/GameState/GameReducer.swift > Sources/GameState/GameController.swift
head -n 953 Sources/GameState/GameReducer.swift > temp_GameReducer.swift
mv temp_GameReducer.swift Sources/GameState/GameReducer.swift

# We need to add imports to GameController.swift
cat << 'IMPORT_EOF' > imports.txt
import CardDB
import Foundation
import HSLogParser
import HSLogTailer
import Observation

IMPORT_EOF

cat imports.txt Sources/GameState/GameController.swift > temp_GameController.swift
mv temp_GameController.swift Sources/GameState/GameController.swift
rm imports.txt
