#import <Foundation/Foundation.h>

#if __has_attribute(swift_private)
#define AC_SWIFT_PRIVATE __attribute__((swift_private))
#else
#define AC_SWIFT_PRIVATE
#endif

/// The resource bundle ID.
static NSString * const ACBundleID AC_SWIFT_PRIVATE = @"uz.smartoila.kids";

/// The "AccentColor" asset catalog color resource.
static NSString * const ACColorNameAccentColor AC_SWIFT_PRIVATE = @"AccentColor";

/// The "ChevronDownSmall" asset catalog image resource.
static NSString * const ACImageNameChevronDownSmall AC_SWIFT_PRIVATE = @"ChevronDownSmall";

/// The "FlagRU" asset catalog image resource.
static NSString * const ACImageNameFlagRU AC_SWIFT_PRIVATE = @"FlagRU";

/// The "IconBack" asset catalog image resource.
static NSString * const ACImageNameIconBack AC_SWIFT_PRIVATE = @"IconBack";

/// The "IconInfo" asset catalog image resource.
static NSString * const ACImageNameIconInfo AC_SWIFT_PRIVATE = @"IconInfo";

/// The "IconNotification" asset catalog image resource.
static NSString * const ACImageNameIconNotification AC_SWIFT_PRIVATE = @"IconNotification";

/// The "IconPencil" asset catalog image resource.
static NSString * const ACImageNameIconPencil AC_SWIFT_PRIVATE = @"IconPencil";

/// The "IconSend" asset catalog image resource.
static NSString * const ACImageNameIconSend AC_SWIFT_PRIVATE = @"IconSend";

/// The "IconSettings" asset catalog image resource.
static NSString * const ACImageNameIconSettings AC_SWIFT_PRIVATE = @"IconSettings";

/// The "IconTrophy" asset catalog image resource.
static NSString * const ACImageNameIconTrophy AC_SWIFT_PRIVATE = @"IconTrophy";

/// The "ProfileCircleBg" asset catalog image resource.
static NSString * const ACImageNameProfileCircleBg AC_SWIFT_PRIVATE = @"ProfileCircleBg";

/// The "SmartOilaMark" asset catalog image resource.
static NSString * const ACImageNameSmartOilaMark AC_SWIFT_PRIVATE = @"SmartOilaMark";

/// The "StatusIcons" asset catalog image resource.
static NSString * const ACImageNameStatusIcons AC_SWIFT_PRIVATE = @"StatusIcons";

/// The "UserAvatarGlyph" asset catalog image resource.
static NSString * const ACImageNameUserAvatarGlyph AC_SWIFT_PRIVATE = @"UserAvatarGlyph";

/// The "WatermarkMark" asset catalog image resource.
static NSString * const ACImageNameWatermarkMark AC_SWIFT_PRIVATE = @"WatermarkMark";

#undef AC_SWIFT_PRIVATE
