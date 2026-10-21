"""Base class for tab frames.

Tkinter is not thread-safe: worker threads must not touch widgets directly.
Tabs historically called ``self.after(0, callback)`` from bridge worker
threads, which is not guaranteed to be safe (and hid exceptions if the
callback was never delivered). ``BaseTab`` marshals those calls onto the
main thread through ``BridgeApp.call_soon`` instead, while leaving normal
main-thread timers untouched.
"""
import threading

import customtkinter as ctk


class BaseTab(ctk.CTkFrame):
    def after(self, ms, func=None, *args):
        if (func is not None and ms == 0
                and threading.current_thread() is not threading.main_thread()):
            app = getattr(self, "app", None)
            if app is not None:
                app.call_soon(func, *args)
                return None
        return super().after(ms, func, *args)
