//
//  CheckError.h
//  Chassis
//
//  Created by Roberto Osorio Goenaga on 6/16/20.
//  Copyright © 2020 Roberto Osorio Goenaga. All rights reserved.
//

#ifndef CheckError_h
#define CheckError_h

#include <stdio.h>
#include <AudioToolbox/AudioToolbox.h>
static OSStatus CheckError(OSStatus error, const char *operation)
{
    if (error == noErr) return noErr;
    
    char errorString[20];
    // see if it appears to be a 4-char-code
    *(UInt32 *)(errorString + 1) = CFSwapInt32HostToBig(error);
    if (isprint(errorString[1]) && isprint(errorString[2]) &&
        isprint(errorString[3]) && isprint(errorString[4])) {
        errorString[0] = errorString[5] = '\'';
        errorString[6] = '\0';
    } else {
        // no, format it as an integer
        sprintf(errorString, "%d", (int)error);
    }
    fprintf(stderr, "Error: %s (%s)\n", operation, errorString);
    return error;
}

#endif /* CheckError_h */
