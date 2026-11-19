package com.wingmanbefree.indialogue

import java.io.File

/** Delete only this app's saved input preference, preserving all other local state. */
internal fun clearInputPreference(file: File) {
    check(!file.exists() || file.delete()) { "Could not clear the saved microphone. Try again before recording." }
}
