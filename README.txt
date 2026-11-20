LIGHTWEIGHT APK BUILDER
=======================
Builds Android projects into APK files without Android Studio.

WHAT YOU NEED
- Windows 10 or 11 (64-bit), internet for the first setup and first build
- About 3 GB free disk space
- Your Android project folder (it must contain gradlew.bat and an "app" folder)

HOW TO USE
1. Extract the ZIP anywhere (a folder without spaces, e.g. C:\APKBuilder, is safest).
2. Double-click Start.bat. A window opens.
3. Click "Install Android Environment".
   - You see exactly what will be downloaded and its size, and must confirm.
   - You must accept the Android SDK license (link shown in the dialog).
   - Downloads are checked against the official checksums.
4. Click "Select Android Project" and pick your project folder
   (for example the PhotoWidgets folder; you can put it in the Projects folder).
5. Click "Build APK". The first build is slow (Gradle downloads libraries).
6. Your APK appears in the APK_Output folder ("Open APK Output").

INSTALL ON YOUR PHONE (optional)
1. Phone: Settings > About phone > tap "Build number" 7 times.
2. Settings > Developer options > turn on USB debugging.
3. Plug in the phone, unlock it, tap Allow on the "USB debugging" prompt.
4. Click "Install on Phone" and confirm. Nothing is installed without your OK.

GOOD TO KNOW
- Portable: nothing is installed system-wide and no environment variables are
  changed. JAVA_HOME and ANDROID_HOME are only set for the tools the app starts.
  Delete the folder to remove everything.
- Your project files are never modified.
- Android build tools: the exact version the project needs is downloaded by
  Gradle on the first build (no more, no less).
- SDK folder can be moved to another drive with "Change SDK Folder"
  (do this before installing).
- If a build fails you get a plain-language hint; the full original error stays
  in the log window and in last_build_log.txt.
- Builds a debug APK (signed with the automatic debug key). Fine for your own
  phone; not for the Play Store.
