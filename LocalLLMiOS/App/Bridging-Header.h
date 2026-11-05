//
//  Bridging header：把系统自带的 zlib / sqlite3 暴露给 Swift。
//  llama.cpp 的 C API 由 XCFramework 的 `import llama` 提供，无需在此引入。
//
#ifndef LocalLLMiOS_Bridging_Header_h
#define LocalLLMiOS_Bridging_Header_h

#import <zlib.h>
#import <sqlite3.h>

#endif /* LocalLLMiOS_Bridging_Header_h */
