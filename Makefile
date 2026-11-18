.DEFAULT_GOAL := help
.PHONY: help build build-macos build-android release test test-video run

help:
	@echo 'make build         构建 Mac App 和 Android APK'
	@echo 'make build-macos   仅构建 Mac App'
	@echo 'make build-android 仅构建 Android APK'
	@echo 'make release      构建并整理 Mac App 与 Android APK 到 release/'
	@echo 'make test          运行本地自动化测试，无需平板'
	@echo 'make test-video    运行测试图实机验证，需一台 USB 平板'
	@echo 'make run           启动已构建的菜单栏 App'

build: build-macos build-android

release: build
	mkdir -p release
	ditto .build/WireView.app release/WireView.app
	cp .build/android/wire-view.apk release/wire-view.apk

build-macos:
	bash macos/build.sh

build-android:
	bash android/build.sh

test:
	bash macos/test.sh

test-video:
	bash macos/test.sh --video

run:
	open '.build/WireView.app'
