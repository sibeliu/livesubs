#!/bin/sh
cd "$(dirname "$0")" && swiftc -O -swift-version 5 -o LiveSubs LiveSubs.swift
