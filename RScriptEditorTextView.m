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
#import "RScriptEditorTextStorage.h"
#import "RScriptEditorTypesetter.h"
#import "RScriptEditorLayoutManager.h"
#import "FoldingSignTextAttachmentCell.h"
#import "RGUI.h"


#pragma mark -
#pragma mark flex init

/**
 * Include all the extern variables and prototypes required for flex (used for syntax highlighting)
 */

#import "RScriptEditorTokens.h"
#import "RdScriptEditorTokens.h"

// R lexer
extern NSUInteger yylex();
extern NSUInteger yyuoffset, yyuleng;
typedef struct yy_buffer_state *YY_BUFFER_STATE;
void yy_switch_to_buffer(YY_BUFFER_STATE);
YY_BUFFER_STATE yy_scan_string (const char *);

// Rd lexer
extern NSUInteger rdlex();
typedef struct rd_buffer_state *RD_BUFFER_STATE;
void rd_switch_to_buffer(RD_BUFFER_STATE);
RD_BUFFER_STATE rd_scan_string (const char *);


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

#define R_SYNTAX_HILITE_BIAS 3000
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

	// we are a subclass of RTextView which has its own awake and we must call it
	[super awakeFromNib];

	SLog(@"RScriptEditorTextView: awakeFromNib <%@>", self);

	prefs = [[NSUserDefaults standardUserDefaults] retain];
	[[Preferences sharedPreferences] addDependent:self];

	lineNumberingEnabled = [Preferences flagForKey:showLineNumbersKey withDefault:NO];

	// <TODO> enable for folding
	// theTextStorage = [[RScriptEditorTextStorage alloc] init];
	theTextStorage = [self textStorage];

	// Set self as delegate for the textView's textStorage to enable syntax highlighting,
	[theTextStorage setDelegate:self];

	// <TODO> enable for folding
	// Make sure using foldingLayoutManager
	// if (![[self layoutManager] isKindOfClass:[RScriptEditorLayoutManager class]]) {
	// 	RScriptEditorLayoutManager *layoutManager = [[RScriptEditorLayoutManager alloc] init];
	// 	[[self textContainer] replaceLayoutManager:layoutManager];
	// 	[layoutManager release];
	// }

	// disabled to get the current text range in textView safer
	[[self layoutManager] setBackgroundLayoutEnabled:NO];
	[[self layoutManager] replaceTextStorage:theTextStorage];

	isSyntaxHighlighting = NO;

	if([prefs objectForKey:highlightCurrentLine] == nil) [prefs setBool:YES forKey:highlightCurrentLine];
	if([prefs objectForKey:indentNewLines] == nil) [prefs setBool:YES forKey:indentNewLines];

	[self setFont:[Preferences unarchivedObjectForKey:RScriptEditorDefaultFont withDefault:[NSFont fontWithName:@"Monaco" size:11]]];

	// Set defaults for general usage
	braceHighlightInterval = [Preferences floatForKey:HighlightIntervalKey withDefault:0.3f];
	argsHints = [Preferences flagForKey:prefShowArgsHints withDefault:YES];
	lineWrappingEnabled = [Preferences flagForKey:enableLineWrappingKey withDefault:YES];
	syntaxHighlightingEnabled = [Preferences flagForKey:showSyntaxColoringKey withDefault:YES];

	deleteBackward = NO;
	startListeningToBoundChanges = NO;
	currentHighlight = -1;

	// For now replaced selectedTextBackgroundColor by redColor
	highlightColorAttr = [[NSDictionary alloc] initWithObjectsAndKeys:[NSColor redColor], NSBackgroundColorAttributeName, nil];

	if([[self delegate] isRdDocument])
		editorToolbar = [[RdEditorToolbar alloc] initWithEditor:[self delegate]];
	else
		editorToolbar = [[REditorToolbar alloc] initWithEditor:[self delegate]];

	[self setAllowsDocumentBackgroundColorChange:YES];
	[self setContinuousSpellCheckingEnabled:NO];

	if(![Preferences flagForKey:enableLineWrappingKey withDefault: YES])
		[scrollView setHasHorizontalScroller:YES];

	if(!lineWrappingEnabled)
		[self updateLineWrappingMode];

	// Re-define tab stops for a better editing
	[self setTabStops];

	// add NSViewBoundsDidChangeNotification to scrollView
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

	c=[Preferences unarchivedObjectForKey:editorSelectionBackgroundColorKey withDefault:nil];
	if (!c) c=[NSColor colorWithDeviceRed:0.71f green:0.835f blue:1.0f alpha:1.0f];
	NSMutableDictionary *attr = [NSMutableDictionary dictionary];
	[attr setDictionary:[self selectedTextAttributes]];
	[attr setObject:c forKey:NSBackgroundColorAttributeName];
	[self setSelectedTextAttributes:attr];
	
	// Rd stuff
	// c=[Preferences unarchivedObjectForKey:sectionRdSyntaxColorKey withDefault:nil];
	// if (c) rdColorSection = c;
	// else rdColorSection=[NSColor colorWithDeviceRed:0.8 green:0.0353 blue:0.02 alpha:1.0];
	// [rdColorSection retain];
	// 
	// c=[Preferences unarchivedObjectForKey:macroArgRdSyntaxColorKey withDefault:nil];
	// if (c) rdColorMacroArg = c;
	// else rdColorMacroArg=[NSColor colorWithDeviceRed:0.0 green:0.0 blue:0.98 alpha:1.0];
	// [rdColorMacroArg retain];
	// 
	// c=[Preferences unarchivedObjectForKey:macroGenRdSyntaxColorKey withDefault:nil];
	// if (c) rdColorMacroGen = c;
	// else rdColorMacroGen=[NSColor colorWithDeviceRed:0.4 green:0.78 blue:0.98 alpha:1.0];
	// [rdColorMacroGen retain]; 
	// 
	// c=[Preferences unarchivedObjectForKey:directiveRdSyntaxColorKey withDefault:nil];
	// if (c) rdColorDirective = c;
	// else rdColorDirective=[NSColor colorWithDeviceRed:0.0 green:0.785 blue:0.0 alpha:1.0];
	// [rdColorDirective retain]; 

	// c=[Preferences unarchivedObjectForKey:commentRdSyntaxColorKey withDefault:nil];
	// if (c) rdColorComment = c;
	// else rdColorComment=[NSColor colorWithDeviceRed:0.1 green:0.55 blue:0.05 alpha:1.0];
	// [rdColorComment retain];

	// c=[Preferences unarchivedObjectForKey:normalRdSyntaxColorKey withDefault:nil];
	// if (c) rdColorNormal = c;
	// else rdColorNormal=[NSColor colorWithDeviceRed:0.0 green:0.0 blue:0.0 alpha:1.0];
	// [rdColorNormal retain]; 


	c=[Preferences unarchivedObjectForKey:editorBackgroundColorKey withDefault:nil];
	if (c) shColorBackground = c;
	else shColorBackground=[NSColor colorWithDeviceRed:1.0 green:1.0 blue:1.0 alpha:1.0];
	[shColorBackground retain]; 

	c=[Preferences unarchivedObjectForKey:editorCurrentLineBackgroundColorKey withDefault:nil];
	if (c) shColorCurrentLine = c;
	else shColorCurrentLine=[NSColor colorWithDeviceRed:0.9 green:0.9 blue:0.9 alpha:0.8];
	[shColorCurrentLine retain]; 

	c=[Preferences unarchivedObjectForKey:editorCursorColorKey withDefault:nil];
	if (c) shColorCursor = c;
	else shColorCursor=[NSColor blackColor];
	[shColorCursor retain]; 
	[self setInsertionPointColor:shColorCursor];

	// Register observers for the when editor background colors preference changes
	[prefs addObserver:self forKeyPath:normalSyntaxColorKey options:NSKeyValueObservingOptionNew context:NULL];
	[prefs addObserver:self forKeyPath:stringSyntaxColorKey options:NSKeyValueObservingOptionNew context:NULL];
	[prefs addObserver:self forKeyPath:numberSyntaxColorKey options:NSKeyValueObservingOptionNew context:NULL];
	[prefs addObserver:self forKeyPath:keywordSyntaxColorKey options:NSKeyValueObservingOptionNew context:NULL];
	[prefs addObserver:self forKeyPath:commentSyntaxColorKey options:NSKeyValueObservingOptionNew context:NULL];
	// [prefs addObserver:self forKeyPath:normalRdSyntaxColorKey options:NSKeyValueObservingOptionNew context:NULL];
	// [prefs addObserver:self forKeyPath:commentRdSyntaxColorKey options:NSKeyValueObservingOptionNew context:NULL];
	// [prefs addObserver:self forKeyPath:sectionRdSyntaxColorKey options:NSKeyValueObservingOptionNew context:NULL];
	// [prefs addObserver:self forKeyPath:macroArgRdSyntaxColorKey options:NSKeyValueObservingOptionNew context:NULL];
	// [prefs addObserver:self forKeyPath:macroGenRdSyntaxColorKey options:NSKeyValueObservingOptionNew context:NULL];
	// [prefs addObserver:self forKeyPath:directiveRdSyntaxColorKey options:NSKeyValueObservingOptionNew context:NULL];
	[prefs addObserver:self forKeyPath:editorBackgroundColorKey options:NSKeyValueObservingOptionNew context:NULL];
	[prefs addObserver:self forKeyPath:editorCurrentLineBackgroundColorKey options:NSKeyValueObservingOptionNew context:NULL];
	[prefs addObserver:self forKeyPath:identifierSyntaxColorKey options:NSKeyValueObservingOptionNew context:NULL];
	[prefs addObserver:self forKeyPath:editorCursorColorKey options:NSKeyValueObservingOptionNew context:NULL];
	[prefs addObserver:self forKeyPath:showSyntaxColoringKey options:NSKeyValueObservingOptionNew context:NULL];
	[prefs addObserver:self forKeyPath:prefShowArgsHints options:NSKeyValueObservingOptionNew context:NULL];
	[prefs addObserver:self forKeyPath:enableLineWrappingKey options:NSKeyValueObservingOptionNew context:NULL];
	[prefs addObserver:self forKeyPath:RScriptEditorDefaultFont options:NSKeyValueObservingOptionNew context:NULL];
	[prefs addObserver:self forKeyPath:HighlightIntervalKey options:NSKeyValueObservingOptionNew context:NULL];
	[prefs addObserver:self forKeyPath:highlightCurrentLine options:NSKeyValueObservingOptionNew context:NULL];
	[prefs addObserver:self forKeyPath:showLineNumbersKey options:NSKeyValueObservingOptionNew context:NULL];
	[prefs addObserver:self forKeyPath:editorSelectionBackgroundColorKey options:NSKeyValueObservingOptionNew context:NULL];

	[self setTextColor:shColorNormal];
	[self setInsertionPointColor:shColorCursor];

#if MAC_OS_X_VERSION_MIN_REQUIRED >= MAC_OS_X_VERSION_10_5
	[[self layoutManager] setAllowsNonContiguousLayout:YES];
#endif


}

- (void)dealloc {
	SLog(@"RScriptEditorTextView: dealloc <%@>", self);

	[theTextStorage release];

	if(editorToolbar) [editorToolbar release];

	if(highlightColorAttr) [highlightColorAttr release];

	if(shColorNormal) [shColorNormal release];
	if(shColorString) [shColorString release];
	if(shColorNumber) [shColorNumber release];
	if(shColorKeyword) [shColorKeyword release];
	if(shColorComment) [shColorComment release];
	if(shColorIdentifier) [shColorIdentifier release];
	if(shColorBackground) [shColorBackground release];
	if(shColorCurrentLine) [shColorCurrentLine release];
	if(shColorCursor) [shColorCursor release];

	// if(rdColorNormal) [rdColorNormal release];
	// if(rdColorComment) [rdColorComment release];
	// if(rdColorSection) [rdColorSection release];
	// if(rdColorMacroArg) [rdColorMacroArg release];
	// if(rdColorMacroGen) [rdColorMacroGen release];
	// if(rdColorDirective) [rdColorDirective release];

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
		if([self isEditable])
			[self performSelector:@selector(doSyntaxHighlighting) withObject:nil afterDelay:0.1];
	} else if ([keyPath isEqualToString:stringSyntaxColorKey]) {
		if(shColorString) [shColorString release];
		shColorString = [[NSUnarchiver unarchiveObjectWithData:[change objectForKey:NSKeyValueChangeNewKey]] retain];
		if([self isEditable])
			[self performSelector:@selector(doSyntaxHighlighting) withObject:nil afterDelay:0.1];
	} else if ([keyPath isEqualToString:numberSyntaxColorKey]) {
		if(shColorNumber) [shColorNumber release];
		shColorNumber = [[NSUnarchiver unarchiveObjectWithData:[change objectForKey:NSKeyValueChangeNewKey]] retain];
		if([self isEditable])
			[self performSelector:@selector(doSyntaxHighlighting) withObject:nil afterDelay:0.1];
	} else if ([keyPath isEqualToString:keywordSyntaxColorKey]) {
		if(shColorKeyword) [shColorKeyword release];
		shColorKeyword = [[NSUnarchiver unarchiveObjectWithData:[change objectForKey:NSKeyValueChangeNewKey]] retain];
		if([self isEditable])
			[self performSelector:@selector(doSyntaxHighlighting) withObject:nil afterDelay:0.1];
	} else if ([keyPath isEqualToString:commentSyntaxColorKey]) {
		if(shColorComment) [shColorComment release];
		shColorComment = [[NSUnarchiver unarchiveObjectWithData:[change objectForKey:NSKeyValueChangeNewKey]] retain];
		if([self isEditable])
			[self performSelector:@selector(doSyntaxHighlighting) withObject:nil afterDelay:0.1];
	} else if ([keyPath isEqualToString:identifierSyntaxColorKey]) {
		if(shColorIdentifier) [shColorIdentifier release];
		shColorIdentifier = [[NSUnarchiver unarchiveObjectWithData:[change objectForKey:NSKeyValueChangeNewKey]] retain];
		if([self isEditable])
			[self performSelector:@selector(doSyntaxHighlighting) withObject:nil afterDelay:0.1];
	// } else if ([keyPath isEqualToString:sectionRdSyntaxColorKey]) {
	// 	if(rdColorSection) [rdColorSection release];
	// 	rdColorSection = [[NSUnarchiver unarchiveObjectWithData:[change objectForKey:NSKeyValueChangeNewKey]] retain];
	// 	if([self isEditable])
	// 		[self performSelector:@selector(doSyntaxHighlighting) withObject:nil afterDelay:0.1];
	// } else if ([keyPath isEqualToString:macroArgRdSyntaxColorKey]) {
	// 	if(rdColorMacroArg) [rdColorMacroArg release];
	// 	rdColorMacroArg = [[NSUnarchiver unarchiveObjectWithData:[change objectForKey:NSKeyValueChangeNewKey]] retain];
	// 	if([self isEditable])
	// 		[self performSelector:@selector(doSyntaxHighlighting) withObject:nil afterDelay:0.1];
	// } else if ([keyPath isEqualToString:macroGenRdSyntaxColorKey]) {
	// 	if(rdColorMacroGen) [rdColorMacroGen release];
	// 	rdColorMacroGen = [[NSUnarchiver unarchiveObjectWithData:[change objectForKey:NSKeyValueChangeNewKey]] retain];
	// 	if([self isEditable])
	// 		[self performSelector:@selector(doSyntaxHighlighting) withObject:nil afterDelay:0.1];
	// } else if ([keyPath isEqualToString:directiveRdSyntaxColorKey]) {
	// 	if(rdColorDirective) [rdColorDirective release];
	// 	rdColorDirective = [[NSUnarchiver unarchiveObjectWithData:[change objectForKey:NSKeyValueChangeNewKey]] retain];
	// 	if([self isEditable])
	// 		[self performSelector:@selector(doSyntaxHighlighting) withObject:nil afterDelay:0.1];
	} else if ([keyPath isEqualToString:editorCursorColorKey]) {
		if(shColorCursor) [shColorCursor release];
		shColorCursor = [[NSUnarchiver unarchiveObjectWithData:[change objectForKey:NSKeyValueChangeNewKey]] retain];
		[self setInsertionPointColor:shColorCursor];
		[self setNeedsDisplayInRect:[self bounds]];
	} else if ([keyPath isEqualToString:identifierSyntaxColorKey]) {
		if(shColorIdentifier) [shColorIdentifier release];
		shColorIdentifier = [[NSUnarchiver unarchiveObjectWithData:[change objectForKey:NSKeyValueChangeNewKey]] retain];
		if([self isEditable])
			[self performSelector:@selector(doSyntaxHighlighting) withObject:nil afterDelay:0.1];
	} else if ([keyPath isEqualToString:editorBackgroundColorKey]) {
		if(shColorBackground) [shColorBackground release];
		shColorBackground = [[NSUnarchiver unarchiveObjectWithData:[change objectForKey:NSKeyValueChangeNewKey]] retain];
		[self setNeedsDisplayInRect:[self bounds]];
	} else if ([keyPath isEqualToString:editorCurrentLineBackgroundColorKey]) {
		if(shColorCurrentLine) [shColorCurrentLine release];
		shColorCurrentLine = [[NSUnarchiver unarchiveObjectWithData:[change objectForKey:NSKeyValueChangeNewKey]] retain];
		[self setNeedsDisplayInRect:[self bounds]];
	} else if ([keyPath isEqualToString:editorSelectionBackgroundColorKey]) {
		NSColor *c = [[NSUnarchiver unarchiveObjectWithData:[change objectForKey:NSKeyValueChangeNewKey]] retain];
		NSMutableDictionary *attr = [NSMutableDictionary dictionary];
		[attr setDictionary:[self selectedTextAttributes]];
		[attr setObject:c forKey:NSBackgroundColorAttributeName];
		[self setSelectedTextAttributes:attr];
		[self setNeedsDisplayInRect:[self bounds]];

	} else if ([keyPath isEqualToString:showSyntaxColoringKey]) {
		syntaxHighlightingEnabled = [[change objectForKey:NSKeyValueChangeNewKey] boolValue];
		if(syntaxHighlightingEnabled) {
			[self performSelector:@selector(doSyntaxHighlighting) withObject:nil afterDelay:0.1];
		} else {
			[theTextStorage removeAttribute:NSForegroundColorAttributeName range:NSMakeRange(0, [[theTextStorage string] length])];
			[self setNeedsDisplayInRect:[self bounds]];
		}

	} else if ([keyPath isEqualToString:enableLineWrappingKey]) {
		[self updateLineWrappingMode];
		[self setNeedsDisplayInRect:[self bounds]];

	} else if ([keyPath isEqualToString:showLineNumbersKey]) {
		lineNumberingEnabled = [[change objectForKey:NSKeyValueChangeNewKey] boolValue];
		if(lineNumberingEnabled) {
			NoodleLineNumberView *theRulerView = [[NoodleLineNumberView alloc] initWithScrollView:scrollView];
			[scrollView setVerticalRulerView:theRulerView];
			[scrollView setHasHorizontalRuler:NO];
			[scrollView setHasVerticalRuler:YES];
			[scrollView setRulersVisible:YES];
			[theRulerView release];
		} else {
			[scrollView setHasHorizontalRuler:NO];
			[scrollView setHasVerticalRuler:NO];
			[scrollView setRulersVisible:NO];
		}
		[self setNeedsDisplay:YES];

	} else if ([keyPath isEqualToString:prefShowArgsHints]) {
		argsHints = [[change objectForKey:NSKeyValueChangeNewKey] boolValue];
		if(!argsHints) {
			[[self delegate] setStatusLineText:@""];
		} else {
			[self currentFunctionHint];
		}

	} else if ([keyPath isEqualToString:highlightCurrentLine]) {
		[self setNeedsDisplayInRect:[self bounds]];

	} else if ([keyPath isEqualToString:RScriptEditorDefaultFont] && ![[[[self window] windowController] document] isRTF] && ![self selectedRange].length) {
			[self setFont:[NSUnarchiver unarchiveObjectWithData:[change objectForKey:NSKeyValueChangeNewKey]]];
			[self setNeedsDisplayInRect:[self bounds]];
	
		} else if ([keyPath isEqualToString:HighlightIntervalKey]) {
		braceHighlightInterval = [Preferences floatForKey:HighlightIntervalKey withDefault:0.3f];
	}
}

- (void)updateLineWrappingMode
{

	NSSize layoutSize;

	lineWrappingEnabled = [Preferences flagForKey:enableLineWrappingKey withDefault: YES];
	[self setHorizontallyResizable:YES];
	if (!lineWrappingEnabled) {
		layoutSize = NSMakeSize(10e6,10e6);
		[scrollView setHasHorizontalScroller:YES];
		[self setMaxSize:layoutSize];
		[[self textContainer] setContainerSize:layoutSize];
		[[self textContainer] setWidthTracksTextView:NO];
	} else {
		[scrollView setHasHorizontalScroller:NO];
		layoutSize = [self maxSize];
		[self setMaxSize:layoutSize];
		[[self textContainer] setContainerSize:layoutSize];
		[[self textContainer] setWidthTracksTextView:YES];
		// Enforce view to be re-layouted correctly
		[[self undoManager] disableUndoRegistration];
		[self selectAll:nil];
		[self cut:nil];
		[self paste:nil];
		[[self undoManager] enableUndoRegistration];
	}
	[[self textContainer] setHeightTracksTextView:NO];

	[[[self enclosingScrollView] verticalRulerView] performSelector:@selector(refresh) withObject:nil afterDelay:0.0f];

}

- (void)drawRect:(NSRect)rect
{
	// Draw background only for screen display but not while printing
	if([NSGraphicsContext currentContextDrawingToScreen]) {

		// Draw textview's background
		[shColorBackground setFill];
		NSRectFill(rect);

		// Highlightes the current query if set in the Pref
		// and if nothing is selected in the text view
		if ([prefs boolForKey:highlightCurrentLine] && ![self selectedRange].length && ![self isSnippetMode]) {
			NSUInteger rectCount;
			NSRange curLineRange = [[self string] lineRangeForRange:[self selectedRange]];
			[theTextStorage ensureAttributesAreFixedInRange:curLineRange];
			NSRectArray queryRects = [[self layoutManager] rectArrayForCharacterRange: curLineRange
														 withinSelectedCharacterRange: curLineRange
																	  inTextContainer: [self textContainer]
																			rectCount: &rectCount ];
			[shColorCurrentLine setFill];
			NSRectFillListUsingOperation(queryRects, rectCount, NSCompositeSourceOver);
		}
	}
	[super drawRect:rect];
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

		[self checkSnippets];

		// Cancel calling doSyntaxHighlighting
		[NSObject cancelPreviousPerformRequestsWithTarget:self 
								selector:@selector(doSyntaxHighlighting) 
								object:nil];

		[self performSelector:@selector(doSyntaxHighlighting) withObject:nil afterDelay:0.01f];

		// Cancel setting undo break point
		[NSObject cancelPreviousPerformRequestsWithTarget:self 
								selector:@selector(breakUndoCoalescing) 
								object:nil];

		// Improve undo behaviour, i.e. it depends how fast the user types
		[self performSelector:@selector(breakUndoCoalescing) withObject:nil afterDelay:0.8];

	}

	deleteBackward = NO;
	startListeningToBoundChanges = YES;

}

#pragma mark -

- (BOOL)lineNumberingEnabled
{
	return lineNumberingEnabled;
}

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

	if (!syntaxHighlightingEnabled || [[self delegate] plain]) return;

	isSyntaxHighlighting = YES;

	NSString *selfstr    = [theTextStorage string];
	NSInteger strlength  = (NSInteger)[selfstr length];


	// do not highlight if text larger than 10MB
	if(strlength > 10000000) return;

	// == Do highlighting partly (max R_SYNTAX_HILITE_BIAS*2 around visibleRange
	// by considering entire lines).

	// Get the text range currently displayed in the view port
	NSRect visibleRect = [[[self enclosingScrollView] contentView] documentVisibleRect];
	NSRange visibleRange = [[self layoutManager] glyphRangeForBoundingRectWithoutAdditionalLayout:visibleRect inTextContainer:[self textContainer]];

	if(!visibleRange.length) {
		isSyntaxHighlighting = NO;
		return;
	}

	NSInteger start = visibleRange.location - R_SYNTAX_HILITE_BIAS;
	if (start > 0)
		while(start > 0) {
			if(CFStringGetCharacterAtIndex((CFStringRef)selfstr, start)=='\n')
				break;
			start--;
		}
	if(start < 0) start = 0;
	NSInteger end = NSMaxRange(visibleRange) + R_SYNTAX_HILITE_BIAS;
	if (end > strlength) {
		end = strlength;
	} else {
		while(end < strlength) {
			if(CFStringGetCharacterAtIndex((CFStringRef)selfstr, end)=='\n')
				break;
			end++;
		}
	}

	NSRange textRange = NSMakeRange(start, end-start);

#if MAC_OS_X_VERSION_MIN_REQUIRED >= MAC_OS_X_VERSION_10_5
	[[self layoutManager] ensureLayoutForCharacterRange:textRange];
#endif

	// only to be sure that nothing went wrongly
	textRange = NSIntersectionRange(textRange, NSMakeRange(0, [theTextStorage length])); 

	if (!textRange.length) {
		isSyntaxHighlighting = NO;
		return;
	}

	[theTextStorage beginEditing];

	NSColor *tokenColor = nil;

	size_t tokenEnd, token;
	NSRange tokenRange;

	// first remove the old colors and kQuote
	// [theTextStorage removeAttribute:NSForegroundColorAttributeName range:textRange];
	// mainly for suppressing auto-pairing in 
	[theTextStorage removeAttribute:kLEXToken range:textRange];

	// initialise flex
	yyuoffset = textRange.location; yyuleng = 0;

	if([[self delegate] isRdDocument]) {

			rd_switch_to_buffer(rd_scan_string(NSStringUTF8String([selfstr substringWithRange:textRange])));

			// now loop through all the tokens
			while ((token = rdlex())) {
		// NSLog(@"t %d", token);
				switch (token) {
					case RDPT_COMMENT:
					    tokenColor = shColorComment;
					    break;
					case RDPT_SECTION:
					    tokenColor = shColorKeyword;
					    break;
					case RDPT_MACRO_ARG:
					    tokenColor = shColorNumber;
					    break;
					case RDPT_MACRO_GEN:
					    tokenColor = shColorNumber;
					    break;
					case RDPT_DIRECTIVE:
					    tokenColor = shColorString;
					    break;
					case RDPT_OTHER:
					    tokenColor = shColorNormal;
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

	} else {

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
	}

	// set current textColor to the color of the caret's position - 1
	// to try to suppress writing in normalColor before syntax highlighting 
	NSUInteger ix = [self selectedRange].location;
	if(ix > 1) {
		NSMutableDictionary *typeAttr = [NSMutableDictionary dictionary];
		[typeAttr setDictionary:[self typingAttributes]];
		NSColor *c = [theTextStorage attribute:NSForegroundColorAttributeName atIndex:ix-1 effectiveRange:nil];
		if(c) [typeAttr setObject:c forKey:NSForegroundColorAttributeName];
		[self setTypingAttributes:typeAttr];
	}

	[theTextStorage endEditing];
	isSyntaxHighlighting = NO;

	[self setNeedsDisplay:YES];

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

-(void)highlightCharacter:(NSNumber*)loc
{
	NSInteger pos = [loc intValue];

	SLog(@"RScriptEditorTextView: highlightCharacter: %d", pos);

	if (pos>=0 && pos<[[self string] length]) {

#if MAC_OS_X_VERSION_MIN_REQUIRED >= MAC_OS_X_VERSION_10_5
		[self showFindIndicatorForRange:NSMakeRange(pos, 1)];
#else
		[self resetHighlights];
		NSLayoutManager *lm = [self layoutManager];
		if (lm) {
			currentHighlight = pos;
			[lm setTemporaryAttributes:highlightColorAttr forCharacterRange:NSMakeRange(pos, 1)];
			[self performSelector:@selector(resetBackgroundColor:) withObject:nil afterDelay:braceHighlightInterval];
		}

#endif

	}
	else SLog(@"highlightCharacter: attempt to set highlight %d beyond the text range 0:%d - I refuse!", pos, [[self string] length] - 1);
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
#pragma mark folding

- (void)foldSelectedLines:(id)sender
{

	NSRange r = [self selectedRange];

	if(r.length < 4) return;

	unichar s = [[self string] characterAtIndex:r.location];
	unichar e = [[self string] characterAtIndex:NSMaxRange(r)-1];

	BOOL wrapCheck = NO;

	if(s == '{' && e == '}') {
		r.location++;
		r.length -= 2;
		wrapCheck = YES;
	} else if(s == '(' && e == ')') {
		r.location++;
		r.length -= 2;
		wrapCheck = YES;
	} else if(s == '[' && e == ']') {
		r.location++;
		r.length -= 2;
		wrapCheck = YES;
	}

	if(!r.length) return;

	if(!wrapCheck && [[self string] characterAtIndex:NSMaxRange(r)-1] == '\n')
		r.length--;

	if(!r.length) return;

	NSString *tooltip = nil;
	if(r.length < 300)
		tooltip = [[self string] substringWithRange:r];
	else
		tooltip = [[[self string] substringWithRange:NSMakeRange(r.location, 300)] stringByAppendingString:@"\n…"];

	[theTextStorage beginEditing];
	[theTextStorage addAttribute:foldingAttributeName value:[NSNumber numberWithBool:YES] range:r];
	[theTextStorage addAttribute:NSCursorAttributeName value:[NSCursor arrowCursor] range:r];
	[theTextStorage addAttribute:NSToolTipAttributeName value:tooltip range:r];
	[theTextStorage endEditing];

	[self didChangeText];
	if(lineNumberingEnabled)
		[[[self enclosingScrollView] verticalRulerView] performSelector:@selector(refresh) withObject:nil afterDelay:0.0f];

	[self setSelectedRange:NSMakeRange(NSMaxRange(r), 0)];
	[self scrollRangeToVisible:[self selectedRange]];

}

- (BOOL)unfoldLinesContainingCharacterAtIndex:(NSUInteger)charIndex
{

	NSTextStorage *textStorage = [self textStorage];
	NSRange range;
	NSNumber *value = [textStorage attribute:foldingAttributeName atIndex:charIndex longestEffectiveRange:&range inRange:NSMakeRange(0, [textStorage length])];

	if (value && [value boolValue] && [self shouldChangeTextInRange:range replacementString:nil]) {
		[textStorage removeAttribute:foldingAttributeName range:range];
		[textStorage removeAttribute:NSCursorAttributeName range:range];
		[textStorage removeAttribute:NSToolTipAttributeName range:range];
		[self didChangeText];
		[self setSelectedRange:NSMakeRange(NSMaxRange(range), 0)];
		if(lineNumberingEnabled)
			[[[self enclosingScrollView] verticalRulerView] performSelector:@selector(refresh) withObject:nil afterDelay:0.0f];
		[self scrollRangeToVisible:[self selectedRange]];
		return YES;
	}
	return NO;
}

- (void)mouseDown:(NSEvent *)event
{

	// <TODO> enable for folding
	[super mouseDown:event];

// 	if(![theTextStorage isKindOfClass:[RScriptEditorTextStorage class]]) [super mouseDown:event];
// 
// 	RScriptEditorLayoutManager *layoutManager = (RScriptEditorLayoutManager*)[self layoutManager];
// 	NSUInteger glyphIndex = [layoutManager glyphIndexForPoint:[self convertPointFromBase:[event locationInWindow]] inTextContainer:[self textContainer]];
// 
// 	[theTextStorage setLineFoldingEnabled:YES];
// 
// 	// trigger unfolding if inside foldingAttachmentCell
// 	if (glyphIndex < [layoutManager numberOfGlyphs]) {
// 		NSUInteger charIndex = [layoutManager characterIndexForGlyphAtIndex:glyphIndex];
// 		NSRange range;
// 		NSNumber *value = [theTextStorage attribute:foldingAttributeName atIndex:charIndex longestEffectiveRange:&range inRange:NSMakeRange(0, [theTextStorage length])];
// 	
// 		if (value && [value boolValue]) {
// 			NSTextAttachment *attachment = [theTextStorage attribute:NSAttachmentAttributeName atIndex:range.location effectiveRange:NULL];
// 	
// 			if (attachment) {
// 				NSTextAttachmentCell *cell = (NSTextAttachmentCell *)[attachment attachmentCell];
// 				NSRect cellFrame;
// 				NSPoint delta;
// 	
// 				glyphIndex = [layoutManager glyphIndexForCharacterAtIndex:range.location];
// 	
// 				cellFrame.origin = [self textContainerOrigin];
// 				cellFrame.size = [layoutManager attachmentSizeForGlyphAtIndex:glyphIndex];
// 	
// 				delta = [layoutManager lineFragmentRectForGlyphAtIndex:glyphIndex effectiveRange:NULL].origin;
// 				cellFrame.origin.x += delta.x;
// 				cellFrame.origin.y += delta.y;
// 	
// 				cellFrame.origin.x += [layoutManager locationForGlyphAtIndex:glyphIndex].x;
// 	
// 				if ([cell wantsToTrackMouseForEvent:event inRect:cellFrame ofView:self atCharacterIndex:range.location] && [cell trackMouse:event inRect:cellFrame ofView:self atCharacterIndex:range.location untilMouseUp:YES]) return;
// 			}
// 		}
// 	}
// 
// 	[theTextStorage setLineFoldingEnabled:NO];
// 
// 	[super mouseDown:event];
// }
// 
// - (void)setSelectedRanges:(NSArray *)ranges affinity:(NSSelectionAffinity)affinity stillSelecting:(BOOL)stillSelectingFlag
// {
// 
// 	if(!stillSelectingFlag) {
// 
// 		if([ranges count] > 0) {
// 
// 			// Adjust range for folded text chunks; additional checks will be made in
// 			// the self's delegate [RDocumentWinCtrl:textViewDidChangeSelection:]
// 
// 			NSRange range = [[ranges objectAtIndex:0] rangeValue];
// 
// 			if(!range.length) {
// 				[super setSelectedRanges:ranges affinity:affinity stillSelecting:stillSelectingFlag];
// 				return;
// 			}
// 
// 			NSRange glyphRange = [[self layoutManager] glyphRangeForCharacterRange:range actualCharacterRange:NULL];
// 
// 			if(glyphRange.location != range.location || glyphRange.length != range.length) {
// 
// 				if([ranges count] == 2)
// 					glyphRange.length += [[ranges objectAtIndex:1] rangeValue].length;
// 
// 				SLog(@"RScriptEditorTextView:setSelectedRanges: adjust range via glyph range from %@ to %@", NSStringFromRange(range), NSStringFromRange(glyphRange));
// 
// 				[super setSelectedRange:glyphRange];
// 				return;
// 
// 			}
// 		}
// 	}
// 
// 	[super setSelectedRanges:ranges affinity:affinity stillSelecting:stillSelectingFlag];

}


- (void)setTypingAttributes:(NSDictionary *)attrs
{
	// we don't want to store foldingAttributeName as a typing attribute
	if ([attrs objectForKey:foldingAttributeName]) {
		NSMutableDictionary *copy = [[attrs mutableCopyWithZone:NULL] autorelease];
		[copy removeObjectForKey:foldingAttributeName];
		attrs = copy;
	}

	[super setTypingAttributes:attrs];
}

#pragma mark -

- (void)updatePreferences
{
	
}
@end
