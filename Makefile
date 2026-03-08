# Set APPDIR when using this Makefile!

all: AppRun-template myapp.desktop myapp.png
	cp AppRun-template $(APPDIR)/AppRun
	cp myapp.desktop myapp.png $(APPDIR)
	./appimagetool-x86_64.AppImage --runtime-file runtime-x86_64 $(APPDIR)
