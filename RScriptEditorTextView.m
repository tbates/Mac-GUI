/*
 *  R.app : a Cocoa front end to: "R A Computer Language for Statistical Data Analysis"
 *  
 *  R.app Copyright notes:
 *                     Copyright (C) 2004-5  The R Foundation
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
 *
 *  RScriptEditorTextView.m
 *
 *  Created by Hans-J. Bibiko on 15/02/2011.
 *
 */


#import "RScriptEditorTextView.h"
#import "RGUI.h"


#pragma mark -
#pragma mark flex init

/**
 * Include all the extern variables and prototypes required for flex (used for syntax highlighting)
 */

#import "RScriptEditorTokens.h"

extern NSUInteger yylex();
extern NSUInteger yyuoffset, yyuleng;
typedef struct yy_buffer_state *YY_BUFFER_STATE;
void yy_switch_to_buffer(YY_BUFFER_STATE);
YY_BUFFER_STATE yy_scan_string (const char *);

#pragma mark -
#pragma mark attribute definition 

#define kAPlinked      @"Linked" // attribute for a via auto-pair inserted char
#define kAPval         @"linked"
#define kLEXToken      @"Quoted" // set via lex to indicate a quoted string
#define kLEXTokenValue @"isMarked"
#define kRkeyword      @"s"      // attribute for found R keywords
#define kQuote         @"Quote"
#define kQuoteValue    @"isQuoted"
#define kValue         @"x"
#define kBTQuote       @"BTQuote"
#define kBTQuoteValue  @"isBTQuoted"

#pragma mark -

#define R_SYNTAX_HILITE_BIAS 2000
#define R_MAX_TEXT_SIZE_FOR_SYNTAX_HIGHLIGHTING 20000000


static inline const char* NSStringUTF8String(NSString* self) 
{
	typedef const char* (*SPUTF8StringMethodPtr)(NSString*, SEL);
	static SPUTF8StringMethodPtr SPNSStringGetUTF8String;
	if (!SPNSStringGetUTF8String) SPNSStringGetUTF8String = (SPUTF8StringMethodPtr)[NSString instanceMethodForSelector:@selector(UTF8String)];
	const char* to_return = SPNSStringGetUTF8String(self, @selector(UTF8String));
	return to_return;
}

static inline void NSMutableAttributedStringAddAttributeValueRange (NSMutableAttributedString* self, NSString* aStr, id aValue, NSRange aRange) 
{
	typedef void (*SPMutableAttributedStringAddAttributeValueRangeMethodPtr)(NSMutableAttributedString*, SEL, NSString*, id, NSRange);
	static SPMutableAttributedStringAddAttributeValueRangeMethodPtr SPMutableAttributedStringAddAttributeValueRange;
	if (!SPMutableAttributedStringAddAttributeValueRange) SPMutableAttributedStringAddAttributeValueRange = (SPMutableAttributedStringAddAttributeValueRangeMethodPtr)[self methodForSelector:@selector(addAttribute:value:range:)];
	SPMutableAttributedStringAddAttributeValueRange(self, @selector(addAttribute:value:range:), aStr, aValue, aRange);
	return;
}

static inline id NSMutableAttributedStringAttributeAtIndex (NSMutableAttributedString* self, NSString* aStr, NSUInteger index, NSRangePointer range) 
{
	typedef id (*SPMutableAttributedStringAttributeAtIndexMethodPtr)(NSMutableAttributedString*, SEL, NSString*, NSUInteger, NSRangePointer);
	static SPMutableAttributedStringAttributeAtIndexMethodPtr SPMutableAttributedStringAttributeAtIndex;
	if (!SPMutableAttributedStringAttributeAtIndex) SPMutableAttributedStringAttributeAtIndex = (SPMutableAttributedStringAttributeAtIndexMethodPtr)[self methodForSelector:@selector(attribute:atIndex:effectiveRange:)];
	id r = SPMutableAttributedStringAttributeAtIndex(self, @selector(attribute:atIndex:effectiveRange:), aStr, index, range);
	return r;
}


@implementation RScriptEditorTextView

- (void)awakeFromNib
{

	SLog(@"RScriptEditorTextView: awakeFromNib <%@>", self);

	prefs = [[NSUserDefaults standardUserDefaults] retain];
	[[Preferences sharedPreferences] addDependent:self];

	[self setFont:[Preferences unarchivedObjectForKey:RScriptEditorDefaultFont withDefault:[NSFont fontWithName:@"Monaco" size:11]]];

	// Set self as delegate for the textView's textStorage to enable syntax highlighting,
	[[self textStorage] setDelegate:self];

	// Set defaults for general usage
	braceHighlightInterval = [[Preferences stringForKey:highlightIntervalKey withDefault: @"0.2"] doubleValue];
	lineNumberingEnabled = [Preferences flagForKey:showLineNumbersKey withDefault:NO];
	argsHints = [Preferences flagForKey:prefShowArgsHints withDefault:YES];
	lineWrappingEnabled = [Preferences flagForKey:enableLineWrappingKey withDefault:YES];
	showMatchingBraces = [Preferences flagForKey:showBraceHighlightingKey withDefault:YES];
	syntaxHighlightingEnabled = [Preferences flagForKey:showSyntaxColoringKey withDefault:YES];

	deleteBackward = NO;
	startListeningToBoundChanges = NO;
	currentHighlight = -1;

	// For now replaced selectedTextBackgroundColor by redColor
	highlightColorAttr = [[NSDictionary alloc] initWithObjectsAndKeys:[NSColor redColor], NSBackgroundColorAttributeName, nil];

	editorToolbar = [[REditorToolbar alloc] initWithEditor:[self delegate]];

	if(lineNumberingEnabled) {

		SLog(@"RScriptEditorTextView: set up line numbering <%@>", self);

		theRulerView = [[NoodleLineNumberView alloc] initWithScrollView:scrollView];
		[scrollView setVerticalRulerView:theRulerView];
		[scrollView setHasHorizontalRuler:NO];
		[scrollView setHasVerticalRuler:YES];
		[scrollView setRulersVisible:YES];
	}
	[self setAllowsDocumentBackgroundColorChange:YES];
	[self setContinuousSpellCheckingEnabled:NO];

	// Re-define tab stops for a better editing
	[self setTabStops];

	// disabled to get the current text range in textView safer
	[[self layoutManager] setBackgroundLayoutEnabled:NO];

	NSSize layoutSize = [self maxSize];
	[self setHorizontallyResizable:YES];
	[self setMaxSize: layoutSize];
	if (!lineWrappingEnabled) {
		[scrollView setHasHorizontalScroller:YES];
		[[self textContainer] setWidthTracksTextView:NO];
	} else {
		[scrollView setHasHorizontalScroller:NO];
		[[self textContainer] setWidthTracksTextView:YES];
	}
	[[self textContainer] setHeightTracksTextView: NO];
	[[self textContainer] setContainerSize:layoutSize];

	// add NSViewBoundsDidChangeNotification to scrollView
	[scrollView setPostsBoundsChangedNotifications:YES];
	[[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(boundsDidChangeNotification:) name:NSViewBoundsDidChangeNotification object:[scrollView contentView]];

	NSColor *c = [Preferences unarchivedObjectForKey:normalSyntaxColorKey withDefault:nil];
	if (c) shColorNormal = c;
	else shColorNormal=[NSColor colorWithDeviceRed:0.025 green:0.085 blue:0.600 alpha:1.0];
	[shColorNormal retain];

	c=[Preferences unarchivedObjectForKey:stringSyntaxColorKey withDefault:nil];
	if (c) shColorString = c;
	else shColorString=[NSColor colorWithDeviceRed:0.690 green:0.075 blue:0.000 alpha:1.0];
	[shColorString retain];	

	c=[Preferences unarchivedObjectForKey:numberSyntaxColorKey withDefault:nil];
	if (c) shColorNumber = c;
	else shColorNumber=[NSColor colorWithDeviceRed:0.020 green:0.320 blue:0.095 alpha:1.0];
	[shColorNumber retain];

	c=[Preferences unarchivedObjectForKey:keywordSyntaxColorKey withDefault:nil];
	if (c) shColorKeyword = c;
	else shColorKeyword=[NSColor colorWithDeviceRed:0.765 green:0.535 blue:0.035 alpha:1.0];
	[shColorKeyword retain];

	c=[Preferences unarchivedObjectForKey:commentSyntaxColorKey withDefault:nil];
	if (c) shColorComment = c;
	else shColorComment=[NSColor colorWithDeviceRed:0.312 green:0.309 blue:0.309 alpha:1.0];
	[shColorComment retain];

	c=[Preferences unarchivedObjectForKey:identifierSyntaxColorKey withDefault:nil];
	if (c) shColorIdentifier = c;
	else shColorIdentifier=[NSColor colorWithDeviceRed:0.0 green:0.0 blue:0.0 alpha:1.0];
	[shColorIdentifier retain]; 

	// Register observers for the when editor background colors preference changes
	[prefs addObserver:self forKeyPath:normalSyntaxColorKey options:NSKeyValueObservingOptionNew context:NULL];
	[prefs addObserver:self forKeyPath:stringSyntaxColorKey options:NSKeyValueObservingOptionNew context:NULL];
	[prefs addObserver:self forKeyPath:numberSyntaxColorKey options:NSKeyValueObservingOptionNew context:NULL];
	[prefs addObserver:self forKeyPath:keywordSyntaxColorKey options:NSKeyValueObservingOptionNew context:NULL];
	[prefs addObserver:self forKeyPath:commentSyntaxColorKey options:NSKeyValueObservingOptionNew context:NULL];
	[prefs addObserver:self forKeyPath:identifierSyntaxColorKey options:NSKeyValueObservingOptionNew context:NULL];
	[prefs addObserver:self forKeyPath:showSyntaxColoringKey options:NSKeyValueObservingOptionNew context:NULL];
	[prefs addObserver:self forKeyPath:prefShowArgsHints options:NSKeyValueObservingOptionNew context:NULL];
	[prefs addObserver:self forKeyPath:enableLineWrappingKey options:NSKeyValueObservingOptionNew context:NULL];

	theTextStorage = [self textStorage];
}

- (void)dealloc {
	SLog(@"RScriptEditorTextView: dealloc <%@>", self);


	if(editorToolbar) [editorToolbar release];

	if(highlightColorAttr) [highlightColorAttr release];

	if(shColorNormal) [shColorNormal release];
	if(shColorString) [shColorString release];
	if(shColorNumber) [shColorNumber release];
	if(shColorKeyword) [shColorKeyword release];
	if(shColorComment) [shColorComment release];
	if(shColorIdentifier) [shColorIdentifier release];

	if(theRulerView) [theRulerView release];

	[[NSNotificationCenter defaultCenter] removeObserver:self];
	[[Preferences sharedPreferences] removeDependent:self];
	if(prefs) [prefs release];

	[super dealloc];

}

/**
 * This method is called as part of Key Value Observing which is used to watch for prefernce changes which effect the interface.
 */
- (void)observeValueForKeyPath:(NSString *)keyPath ofObject:(id)object change:(NSDictionary *)change context:(void *)context
{

	if ([keyPath isEqualToString:normalSyntaxColorKey]) {
		if(shColorNormal) [shColorNormal release];
		shColorNormal = [[NSUnarchiver unarchiveObjectWithData:[change objectForKey:NSKeyValueChangeNewKey]] retain];
		if([[self string] length]<100000 && [self isEditable])
			[self performSelector:@selector(doSyntaxHighlighting) withObject:nil afterDelay:0.1];
	} else if ([keyPath isEqualToString:stringSyntaxColorKey]) {
		if(shColorString) [shColorString release];
		shColorString = [[NSUnarchiver unarchiveObjectWithData:[change objectForKey:NSKeyValueChangeNewKey]] retain];
		if([[self string] length]<100000 && [self isEditable])
			[self performSelector:@selector(doSyntaxHighlighting) withObject:nil afterDelay:0.1];
	} else if ([keyPath isEqualToString:numberSyntaxColorKey]) {
		if(shColorNumber) [shColorNumber release];
		shColorNumber = [[NSUnarchiver unarchiveObjectWithData:[change objectForKey:NSKeyValueChangeNewKey]] retain];
		if([[self string] length]<100000 && [self isEditable])
			[self performSelector:@selector(doSyntaxHighlighting) withObject:nil afterDelay:0.1];
	} else if ([keyPath isEqualToString:keywordSyntaxColorKey]) {
		if(shColorKeyword) [shColorKeyword release];
		shColorKeyword = [[NSUnarchiver unarchiveObjectWithData:[change objectForKey:NSKeyValueChangeNewKey]] retain];
		if([[self string] length]<100000 && [self isEditable])
			[self performSelector:@selector(doSyntaxHighlighting) withObject:nil afterDelay:0.1];
	} else if ([keyPath isEqualToString:commentSyntaxColorKey]) {
		if(shColorComment) [shColorComment release];
		shColorComment = [[NSUnarchiver unarchiveObjectWithData:[change objectForKey:NSKeyValueChangeNewKey]] retain];
		if([[self string] length]<100000 && [self isEditable])
			[self performSelector:@selector(doSyntaxHighlighting) withObject:nil afterDelay:0.1];
	} else if ([keyPath isEqualToString:identifierSyntaxColorKey]) {
		if(shColorIdentifier) [shColorIdentifier release];
		shColorIdentifier = [[NSUnarchiver unarchiveObjectWithData:[change objectForKey:NSKeyValueChangeNewKey]] retain];
		if([[self string] length]<100000 && [self isEditable])
			[self performSelector:@selector(doSyntaxHighlighting) withObject:nil afterDelay:0.1];
	} else if ([keyPath isEqualToString:showSyntaxColoringKey]) {
		syntaxHighlightingEnabled = [[change objectForKey:NSKeyValueChangeNewKey] boolValue];
		if(syntaxHighlightingEnabled) {
			[self performSelector:@selector(doSyntaxHighlighting) withObject:nil afterDelay:0.1];
		} else {
			[theTextStorage removeAttribute:NSForegroundColorAttributeName range:NSMakeRange(0, [[theTextStorage string] length])];
		}
	} else if ([keyPath isEqualToString:enableLineWrappingKey]) {
		lineWrappingEnabled = [[change objectForKey:NSKeyValueChangeNewKey] boolValue];
		NSSize layoutSize = NSMakeSize(10e6,10e6);
		[self setHorizontallyResizable:YES];
		[self setMaxSize: layoutSize];
		[[self textContainer] setContainerSize:layoutSize];
		if (!lineWrappingEnabled) {
			[scrollView setHasHorizontalScroller:YES];
			[[self textContainer] setWidthTracksTextView:NO];
		} else {
			[[self textContainer] setContainerSize:[self bounds].size];
			[scrollView setHasHorizontalScroller:NO];
			[[self textContainer] setWidthTracksTextView:YES];
		}
		[[self textContainer] setHeightTracksTextView:NO];

		[[NSNotificationCenter defaultCenter] postNotificationName:NSWindowDidResizeNotification object:[[self delegate] window]];

	} else if ([keyPath isEqualToString:prefShowArgsHints]) {
		argsHints = [[change objectForKey:NSKeyValueChangeNewKey] boolValue];
		if(!argsHints) {
			[[self delegate] setStatusLineText:@""];
		}
	}

}

#pragma mark -

/**
 *  Performs syntax highlighting, trigger undo behaviour
 */
- (void)textStorageDidProcessEditing:(NSNotification *)notification
{

	// Make sure that the notification is from the correct textStorage object
	if (theTextStorage != [notification object]) return;

	NSInteger editedMask = [theTextStorage editedMask];

	SLog(@"RScriptEditorTextView: textStorageDidProcessEditing <%@> with mask %d", self, editedMask);

	// if the user really changed the text
	if(editedMask != 1) {

		// Cancel setting undo break point
		[NSObject cancelPreviousPerformRequestsWithTarget:self 
								selector:@selector(breakUndoCoalescing) 
								object:nil];

		// Cancel calling doSyntaxHighlighting
		[NSObject cancelPreviousPerformRequestsWithTarget:self 
								selector:@selector(doSyntaxHighlighting) 
								object:nil];

		// Cancel calling doSyntaxHighlighting
		[NSObject cancelPreviousPerformRequestsWithTarget:[self delegate] 
								selector:@selector(functionRescan) 
								object:nil];

		[self performSelector:@selector(doSyntaxHighlighting) withObject:nil afterDelay:0.0];

		// Improve undo behaviour, i.e. it depends how fast the user types
		[self performSelector:@selector(breakUndoCoalescing) withObject:nil afterDelay:0.8];

		[[self delegate] performSelector:@selector(functionRescan) withObject:nil afterDelay:0.05];

	}

	deleteBackward = NO;
	startListeningToBoundChanges = YES;

}

#pragma mark -

- (void)setDeleteBackward:(BOOL)delBack
{
	deleteBackward = delBack;
}

/**
 * Sets Tab Stops width for better editing behaviour
 */
- (void)setTabStops
{

	SLog(@"RScriptEditorTextView: setTabStops <%@>", self);

	NSFont *tvFont = [self font];
	int i;
	NSTextTab *aTab;
	NSMutableArray *myArrayOfTabs;
	NSMutableParagraphStyle *paragraphStyle;

	BOOL oldEditableStatus = [self isEditable];
	[self setEditable:YES];

	int tabStopWidth = [Preferences integerForKey:RScriptEditorTabWidth withDefault:4];
	if(tabStopWidth < 1) tabStopWidth = 1;

	float theTabWidth = [[NSString stringWithString:@" "] sizeWithAttributes:[NSDictionary dictionaryWithObject:tvFont forKey:NSFontAttributeName]].width;
	theTabWidth = (float)tabStopWidth * theTabWidth;

	int numberOfTabs = 256/tabStopWidth;
	myArrayOfTabs = [NSMutableArray arrayWithCapacity:numberOfTabs];
	aTab = [[NSTextTab alloc] initWithType:NSLeftTabStopType location:theTabWidth];
	[myArrayOfTabs addObject:aTab];
	[aTab release];
	for(i=1; i<numberOfTabs; i++) {
		aTab = [[NSTextTab alloc] initWithType:NSLeftTabStopType location:theTabWidth + ((float)i * theTabWidth)];
		[myArrayOfTabs addObject:aTab];
		[aTab release];
	}
	paragraphStyle = [[NSParagraphStyle defaultParagraphStyle] mutableCopy];
	[paragraphStyle setTabStops:myArrayOfTabs];

	// Soft wrapped lines are indented slightly
	[paragraphStyle setHeadIndent:4.0];

	NSMutableDictionary *textAttributes = [[[NSMutableDictionary alloc] initWithCapacity:1] autorelease];
	[textAttributes setObject:paragraphStyle forKey:NSParagraphStyleAttributeName];

	NSRange range = NSMakeRange(0, [theTextStorage length]);
	if ([self shouldChangeTextInRange:range replacementString:nil]) {
		[theTextStorage setAttributes:textAttributes range: range];
		[self didChangeText];
	}
	[self setTypingAttributes:textAttributes];
	[self setDefaultParagraphStyle:paragraphStyle];
	[self setFont:tvFont];

	[self setEditable:oldEditableStatus];

	[paragraphStyle release];
}

/**
 * Syntax Highlighting.
 *  
 * (The main bottleneck is the [NSTextStorage addAttribute:value:range:] method - the parsing itself is really fast!)
 * Some sample code from Andrew Choi ( http://members.shaw.ca/akochoi-old/blog/2003/11-09/index.html#3 ) has been reused.
 */
- (void)doSyntaxHighlighting
{

	if (!syntaxHighlightingEnabled || [[self delegate] plain] || [theTextStorage length] > 40000000) return;

	NSString *selfstr        = [theTextStorage string];
	NSUInteger strlength     = [selfstr length];

	// Avoid syntax highlighting of a big change but re-trigger it for highlighting it partly
	if([theTextStorage editedRange].length > (int)(R_SYNTAX_HILITE_BIAS * 4)) {
		[self insertText:@""];
		// remove inserting action from undo manager is keep edit status
		[[self undoManager] undo];
		return;
	}

	// Do highlighting partly (max R_SYNTAX_HILITE_BIAS*2).
	// The approach is to take the middle position of the current view port
	// and highlight only ±R_SYNTAX_HILITE_BIAS of that middle position
	// considering of line starts resp. ends

	// Get the text range currently displayed in the view port
	NSRect visibleRect = [[[self enclosingScrollView] contentView] documentVisibleRect];
	NSRange visibleRange = [[self layoutManager] glyphRangeForBoundingRectWithoutAdditionalLayout:visibleRect inTextContainer:[self textContainer]];

	if(!visibleRange.length) return;

	// Take roughly the middle position in the current view port
	NSUInteger curPos = visibleRange.location+(NSUInteger)(visibleRange.length/2);

	// get the last line to parse due to R_SYNTAX_HILITE_BIAS
	// but look for only R_SYNTAX_HILITE_BIAS chars forwards
	NSUInteger end = curPos + R_SYNTAX_HILITE_BIAS;
	NSInteger lengthChecker = R_SYNTAX_HILITE_BIAS;
	if (end > strlength ) {
		end = strlength;
	} else {
		while(end < strlength && lengthChecker > 0) {
			if(CFStringGetCharacterAtIndex((CFStringRef)selfstr, end)=='\n')
				break;
			end++;
			lengthChecker--;
		}
	}
	if(lengthChecker <= 0)
		end = curPos + R_SYNTAX_HILITE_BIAS;

	// get the first line to parse due to R_SYNTAX_HILITE_BIAS
	// but look for only R_SYNTAX_HILITE_BIAS chars backwards
	NSUInteger start, start_temp;
	if(end <= (R_SYNTAX_HILITE_BIAS*2))
	 	start = 0;
	else
	 	start = end - (R_SYNTAX_HILITE_BIAS*2);

	start_temp = start;
	lengthChecker = R_SYNTAX_HILITE_BIAS;
	if (start > 0)
		while(start>0 && lengthChecker > 0) {
			if(CFStringGetCharacterAtIndex((CFStringRef)selfstr, start)=='\n')
				break;
			start--;
			lengthChecker--;
		}
	if(lengthChecker <= 0)
		start = start_temp;

	NSRange textRange = NSMakeRange(start, end-start);

	// only to be sure that nothing went wrongly
	textRange = NSIntersectionRange(textRange, NSMakeRange(0, [theTextStorage length])); 

	if (!textRange.length)
		return;

	[theTextStorage beginEditing];

	NSColor *tokenColor;

	size_t tokenEnd, token;
	NSRange tokenRange;

	// first remove the old colors and kQuote
	[theTextStorage removeAttribute:NSForegroundColorAttributeName range:textRange];
	// mainly for suppressing auto-pairing in 
	[theTextStorage removeAttribute:kLEXToken range:textRange];

	// initialise flex
	yyuoffset = textRange.location; yyuleng = 0;
	yy_switch_to_buffer(yy_scan_string(NSStringUTF8String([selfstr substringWithRange:textRange])));

	// now loop through all the tokens
	while ((token = yylex())) {
// NSLog(@"t %d", token);
		switch (token) {
			case RPT_SINGLE_QUOTED_TEXT:
			case RPT_DOUBLE_QUOTED_TEXT:
			    tokenColor = shColorString;
			    break;
			case RPT_RESERVED_WORD:
			    tokenColor = shColorKeyword;
			    break;
			case RPT_NUMERIC:
				tokenColor = shColorNumber;
				break;
			case RPT_BACKTICK_QUOTED_TEXT:
			    tokenColor = shColorString;
			    break;
			case RPT_COMMENT:
			    tokenColor = shColorComment;
			    break;
			case RPT_VARIABLE:
			    tokenColor = shColorIdentifier;
			    break;
			case RPT_WHITESPACE:
			    continue;
			    break;
			default:
			    tokenColor = shColorNormal;
		}

		tokenRange = NSMakeRange(yyuoffset, yyuleng);

		// make sure that tokenRange is valid (and therefore within textRange)
		// otherwise a bug in the lex code could cause the the TextView to crash
		// NOTE Disabled for testing purposes for speed it up
		tokenRange = NSIntersectionRange(tokenRange, textRange);
		if (!tokenRange.length) continue;

		// If the current token is marked as SQL keyword, uppercase it if required.
		tokenEnd = NSMaxRange(tokenRange) - 1;

		NSMutableAttributedStringAddAttributeValueRange(theTextStorage, NSForegroundColorAttributeName, tokenColor, tokenRange);
		
		// if(!allowToCheckForUpperCase) continue;
		
		// Add an attribute to be used in the auto-pairing (keyDown:)
		// to disable auto-pairing if caret is inside of any token found by lex.
		// For discussion: maybe change it later (only for quotes not keywords?)
		if(token < 6)
			NSMutableAttributedStringAddAttributeValueRange(theTextStorage, kLEXToken, kLEXTokenValue, tokenRange);
		

		// Add an attribute to be used to distinguish quotes from keywords etc.
		// used e.g. in completion suggestions
		else if(token < 4)
			NSMutableAttributedStringAddAttributeValueRange(theTextStorage, kQuote, kQuoteValue, tokenRange);
		

	}
	[theTextStorage endEditing];

}

-(void)resetHighlights
{
	SLog(@"RScriptEditorTextView: resetHighlights with current highlite %d", currentHighlight);

	if (currentHighlight>-1) {
		if (currentHighlight<[theTextStorage length]) {
			NSLayoutManager *lm = [self layoutManager];
			if (lm) {
				NSRange fr = NSMakeRange(currentHighlight,1);
				NSDictionary *d = [lm temporaryAttributesAtCharacterIndex:currentHighlight effectiveRange:&fr];
				if (!d || [d objectForKey:NSBackgroundColorAttributeName]==nil) {
					fr = NSMakeRange(0,[[self string] length]);
					SLog(@"resetHighlights: attribute at %d not found, clearing all %d characters - better safe than sorry", currentHighlight, fr.length);
				}
				[lm removeTemporaryAttribute:NSBackgroundColorAttributeName forCharacterRange:fr];
			}
		}
		currentHighlight=-1;
	}
}

-(void)highlightCharacter:(int)pos
{

	SLog(@"RScriptEditorTextView: highlightCharacter: %d", pos);

	[self resetHighlights];

	if (pos>=0 && pos<[[self string] length]) {
		NSLayoutManager *lm = [self layoutManager];
		if (lm) {
			currentHighlight = pos;
			[lm setTemporaryAttributes:highlightColorAttr forCharacterRange:NSMakeRange(pos, 1)];
			[self performSelector:@selector(resetBackgroundColor:) withObject:nil afterDelay:braceHighlightInterval];
		} else SLog(@"highlightCharacter: attempt to set highlight %d beyond the text range 0:%d - I refuse!", pos, [self length]-1);
	}
}

-(void)resetBackgroundColor:(id)sender
{
	[self resetHighlights];
}

/**
 * Scrollview delegate after the textView's view port was changed.
 * Manily used to update the syntax highlighting for a large text size, line numbering rendering, and
 * status line size checking
 */
- (void)boundsDidChangeNotification:(NSNotification *)notification
{

	if(startListeningToBoundChanges) {
		[NSObject cancelPreviousPerformRequestsWithTarget:self 
									selector:@selector(doSyntaxHighlighting) 
									object:nil];

		if(![theTextStorage changeInLength]) {
			[self performSelector:@selector(doSyntaxHighlighting) withObject:nil afterDelay:0.05];

		}
	}

}

#pragma mark -

- (void)updatePreferences
{
	
}
@end