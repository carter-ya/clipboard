FROM ubuntu:22.04
ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update -qq && apt-get install -y --no-install-recommends libcurl4 libxml2 libicu70 libssl3 libgtk-4-1 libx11-6 libxfixes3 libdbus-1-3 libsecret-1-0 libtesseract4 liblept5 tesseract-ocr-eng tesseract-ocr-chi-sim gnome-keyring python3-pyatspi python3-gi xvfb xauth xclip dbus-x11 openbox imagemagick x11-utils fonts-noto-cjk fonts-noto-color-emoji ca-certificates && rm -rf /var/lib/apt/lists/*
