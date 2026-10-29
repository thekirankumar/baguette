#pragma once
#import <Foundation/Foundation.h>
#include <math.h>
#include <stdio.h>
#include <stdlib.h>

// Native enum values consumed by the simulator's orientation-picker-control.
static BOOL isHingeOrientation(NSString *value) {
  return [@[@"portrait", @"pud", @"landscape-left", @"landscape-right"] containsObject:value];
}

// Shared by one-shot and serving commands: usage error 2, dispatch error 1.
static int dispatchHingeOrientation(NSString *value, BOOL (^send)(const char *)) {
  if (!isHingeOrientation(value)) return 2;
  return send(value.UTF8String) ? 0 : 1;
}

// The host's side of a helper. `--deadline <unix-seconds>` precedes the verb:
// a helper not ready to act by then exits with this status and does nothing,
// so a host that stopped waiting knows a late start cannot move the device.
static const int HingeDeadlinePassedStatus = 3;

static BOOL parseHingeDeadline(const char *text, double *deadline) {
  char *end = NULL;
  double value = strtod(text, &end);
  if (end == text || *end != '\0' || !isfinite(value)) return NO;
  *deadline = value;
  return YES;
}

static BOOL hingeDeadlinePassed(double deadline) {
  return [NSDate date].timeIntervalSince1970 > deadline;
}

// Plays commands one per line until EOF. Each is answered with
// `done <status>` once played: 0 success, 1 dispatch failure, 2 invalid.
static void serveHingeCommands(FILE *input, FILE *output, int (^perform)(NSArray<NSString *> *)) {
  char *line = NULL;
  size_t capacity = 0;
  while (getline(&line, &capacity, input) > 0) {
    NSString *text = [[NSString stringWithUTF8String:line]
      stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (!text.length) continue;
    int status = perform([text componentsSeparatedByCharactersInSet:[NSCharacterSet whitespaceCharacterSet]]);
    if (status) fprintf(stderr, "%s: %s\n", status == 2 ? "bad line" : "dispatch failed", text.UTF8String);
    fprintf(output, "done %d\n", status);
    fflush(output);
  }
  free(line);
}

// `button <page> <usage> <ms> [<page> <usage>]…`, the words after the verb.
// Trailing pairs are modifiers: down in order before the key, up in reverse
// after it, so a shifted letter or a Cmd chord types as on a keyboard.
// Whatever went down is released even when a press is refused.
static int dispatchHingeButton(NSArray<NSString *> *words, BOOL (^key)(unsigned page, unsigned usage, BOOL down),
                               void (^hold)(unsigned ms)) {
  if (words.count < 3 || (words.count - 3) % 2) return 2;
  unsigned values[words.count];
  for (NSUInteger i = 0; i < words.count; i++) {
    const char *text = words[i].UTF8String;
    char *end = NULL;
    unsigned long value = strtoul(text, &end, 0);
    if (end == text || *end != '\0') return 2;
    values[i] = (unsigned)value;
  }
  NSUInteger modifiers = (words.count - 3) / 2;
  BOOL ok = YES;
  for (NSUInteger m = 0; m < modifiers; m++) ok = key(values[3 + 2 * m], values[4 + 2 * m], YES) && ok;
  ok = key(values[0], values[1], YES) && ok;
  hold(values[2]);
  ok = key(values[0], values[1], NO) && ok;
  for (NSUInteger m = modifiers; m > 0; m--) ok = key(values[1 + 2 * m], values[2 + 2 * m], NO) && ok;
  return ok ? 0 : 1;
}
