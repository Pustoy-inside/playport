/* SPDX-License-Identifier: GPL-3.0-or-later */
/*
 * touchpad.h: the on-screen controller (touchpad.m). It sets itself up from
 * its constructor; the app calls playport_touchpad_linked() only so that the
 * linker keeps the object that holds it.
 */
#ifndef PLAYPORT_TOUCHPAD_H
#define PLAYPORT_TOUCHPAD_H

void playport_touchpad_linked(void);

#endif
