/*
 *  R.app : a Cocoa front end to: "R A Computer Language for Statistical Data Analysis"
 *  
 *  R.app Copyright notes:
 *                     Copyright (C) 2004  The R Foundation
 *                     written by Stefano M. Iacus and Simon Urbanek
 *
 *                  
 *  R Copyright notes:
 *                     Copyright (C) 1995-1996   Robert Gentleman and Ross Ihaka
 *                     Copyright (C) 1998-2001   The R Development Core Team
 *                     Copyright (C) 2002-2004   The R Foundation
 *
 *  This program is free software; you can redistribute it and/or modify
 *  it under the terms of the GNU General Public License as published by
 *  the Free Software Foundation; either version 2 of the License, or
 *  (at your option) any later version.
 *
 *  This program is distributed in the hope that it will be useful,
 *  but WITHOUT ANY WARRANTY; without even the implied warranty of
 *  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 *  GNU General Public License for more details.
 *
 *  A copy of the GNU General Public License is available via WWW at
 *  http://www.gnu.org/copyleft/gpl.html.  You can also obtain it by
 *  writing to the Free Software Foundation, Inc., 59 Temple Place,
 *  Suite 330, Boston, MA  02111-1307  USA.
 */


#import "History.h"
#import "RController.h"
#import "RDocumentController.h"


@implementation History
/** implements a history with one dirt entry (i.e. an entry which is still being edited but not cimmited yet) */

- (id) init {
    hist = [[NSMutableArray alloc] initWithCapacity: 16];
    dirtyEntry=nil;
    pos=0;
    return self;
}


- (void) setHist: (NSArray *) entries{
	if(hist) 
		[self resetAll];
	[hist addObjectsFromArray: entries];
}

- (void) dealloc {
    [self resetAll];
    [hist release];
    [super dealloc];
}


/** commits an entry to the end of the history, except it equals to the last entry; moves the current position past the last entry and also deletes any dirty entry */
- (void) commit: (NSString*) entry {
    int ac = [hist count];
    if (ac==0 || ![[hist objectAtIndex: ac-1] isEqualToString:entry]) { // only add if it's not equal to the last one
        [hist addObject: entry];
    }
    if (dirtyEntry!=nil) [dirtyEntry release];
    dirtyEntry=nil;
    pos=[hist count];
}

- (void)importHistory {
	[[RController getRController] doClearHistory:nil];
	FILE *rhist;
	NSString * fname;
	char c[1000];
	int cc;
	int j = 0;
	int i;
	BOOL done;
	fname = [[Preferences stringForKey:historyFileNamePathKey
						   withDefault: @"~/.Rhistory"] stringByExpandingTildeInPath];
	if ([[NSFileManager defaultManager] fileExistsAtPath: fname]) {
		rhist = fopen([fname cString], "r");
		if (rhist==NULL) {
			NSLog(NLS(@"Can't open history file %2"), fname);
		} else {
			cc = fgetc(rhist);
			while( cc != EOF ) {				
				done = FALSE;
				for (i=0;i<1000 && !done && cc!=EOF;i++) {
					c[i] = cc;
					if (cc == '\n' || i==999) {
						if (i==0) {											// Empty line
							cc = fgetc(rhist);
							done = TRUE;
						} else {
							c[i]=0;												// Don't want a newline
							[self commit:[[NSString alloc] initWithCString:&c[0]]];
							cc = fgetc(rhist);
							j++;
							done = TRUE;
						}
					} else {													// Keep collecting chars
						cc = fgetc(rhist);
						if (cc == EOF) {
							if (i>0) {
								j++;
								c[i+1]=0;										// Don't want a newline
								[self commit:[[NSString alloc] initWithCString:&c[0]]];
							}
							done=TRUE;
						}						
					}
				}
			}
		}
	}
	if (j>250) {
		j = j - 200;
		for (i=0;i<j;i++)
			[hist removeObjectAtIndex:0];
	}
	pos = [hist count];
	fclose(rhist);	
}

- (void)exportHistory {
	FILE *rhist;
	NSString * fname;
	fname = [[Preferences stringForKey:historyFileNamePathKey
						   withDefault: @"~/.Rhistory"] stringByExpandingTildeInPath];
	if ([[NSFileManager defaultManager] fileExistsAtPath: fname]) {
		rhist = fopen([fname cString], "r");
		if (rhist==NULL) {
			NSLog(NLS(@"Can't open history file %2"), fname);
		} else {
			int ac = [hist count];
			rhist = fopen([fname cString], "w");
			int i;
			for (i=0 ; i < ac ; i++) {
				fprintf(rhist, "%s\n", [[hist objectAtIndex:i] cString]);		
			}
			fclose(rhist);	
		}
	}
}

- (void)editHistory {
	[self exportHistory];
	NSString *fname = [[Preferences stringForKey:historyFileNamePathKey
							withDefault: @"~/.Rhistory"] stringByExpandingTildeInPath];
	[[NSDocumentController sharedDocumentController] openNamedFile:fname display:YES];
}

/** moves to the next entry; if out of the history, returns the dirty entry */
- (NSString*) next {
    int ac = [hist count];
    if (pos<ac) {
        pos++;
        if (pos<ac) return (NSString*) [hist objectAtIndex: pos];
    }
    // we're past the history, always return the dirty entry
    return dirtyEntry;
}

/** moves to the previous entry; if past the beginning, returns nil */
- (NSString*) prev {
    if (pos>0) { pos--; return (NSString*) [hist objectAtIndex: pos]; };
    return nil;
}

/** returns the current entry (can be the dirty entry, too) */
- (NSString*) current {
    int ac = [hist count];
    if (pos<ac) return (NSString*) [hist objectAtIndex: pos];
    return dirtyEntry;
}

/** returns YES if the current position is in the dirty entry */
- (BOOL) isDirty {
    return (pos==[hist count])?YES:NO;
}

/** updates the dirty entry with teh passed string, iff we're currently in the dirty position */
- (void) updateDirty: (NSString*) entry {
    if (pos==[hist count]) {
        if (entry==dirtyEntry) return;
        if (dirtyEntry!=nil) [dirtyEntry release];
        dirtyEntry=(entry==nil)?nil:[entry copy];
    }
}

/** resets the entire history, position and ditry entry */
- (void) resetAll {
    [hist removeAllObjects];
    if (dirtyEntry!=nil) [dirtyEntry release];
    pos=0;
}

/** returns a snapshot of the current histroy (w/o the dirty entry). you will need to release the resulting object. */
- (NSArray*) entries {
    return [NSArray arrayWithArray: hist];
}

- (void) encodeWithCoder:(NSCoder *)coder{
	[coder encodeObject:[self entries]];
}

- (id) initWithCoder:(NSCoder *)coder{
	[self setHist:[coder decodeObject]];
	return self;
}

- (void)updatePreferences {
	
}

@end
