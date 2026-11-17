"""在 WSL 中向指定 MioLib 的文件共享区传入中文样书，并读回校验。"""
import argparse
import ctypes as c
import ctypes.util
import hashlib
import json
import plistlib
from pathlib import Path
import uuid


# 仅绑定测试所需的公开 C 接口，不读取其他应用或设备上的私人资料。
mobile = c.CDLL(ctypes.util.find_library("imobiledevice-1.0"))
plist = c.CDLL(ctypes.util.find_library("plist-2.0"))
libc = c.CDLL(None)
ptr = c.c_void_p
ptr_out = c.POINTER(ptr)
u64 = c.c_uint64
u32 = c.c_uint32
char_array = c.POINTER(c.c_char_p)


# 显式声明指针与整数宽度，避免 ctypes 默认返回类型截断 64 位地址。
def bind(library, name, args, result=c.c_int):
    function = getattr(library, name)
    function.argtypes = args
    function.restype = result
    return function


device_new = bind(mobile, "idevice_new", [ptr_out, c.c_char_p])
device_free = bind(mobile, "idevice_free", [ptr])
house_start = bind(mobile, "house_arrest_client_start_service", [ptr, ptr_out, c.c_char_p])
house_send = bind(mobile, "house_arrest_send_command", [ptr, c.c_char_p, c.c_char_p])
house_result = bind(mobile, "house_arrest_get_result", [ptr, ptr_out])
house_free = bind(mobile, "house_arrest_client_free", [ptr])
afc_new = bind(mobile, "afc_client_new_from_house_arrest_client", [ptr, ptr_out])
afc_free = bind(mobile, "afc_client_free", [ptr])
file_info = bind(mobile, "afc_get_file_info", [ptr, c.c_char_p, c.POINTER(char_array)])
dictionary_free = bind(mobile, "afc_dictionary_free", [char_array])
file_open = bind(mobile, "afc_file_open", [ptr, c.c_char_p, c.c_int, c.POINTER(u64)])
file_write = bind(mobile, "afc_file_write", [ptr, u64, c.c_char_p, u32, c.POINTER(u32)])
file_read = bind(mobile, "afc_file_read", [ptr, u64, ptr, u32, c.POINTER(u32)])
file_close = bind(mobile, "afc_file_close", [ptr, u64])
to_xml = bind(plist, "plist_to_xml", [ptr, ptr_out, c.POINTER(u32)], None)
plist_free = bind(plist, "plist_free", [ptr], None)
memory_free = bind(libc, "free", [ptr], None)


# 所有设备错误立即停止，不覆盖、不清理已有传入文件。
def checked(code, operation):
    if code != 0:
        raise RuntimeError(f"{operation}: error {code}")


# 服务应答的 plist 与 XML 缓冲区分别释放，避免测试工具本身泄漏。
def response(client):
    node, xml, size = ptr(), ptr(), u32()
    checked(house_result(client, c.byref(node)), "读取文件共享应答")
    try:
        to_xml(node, c.byref(xml), c.byref(size))
        return plistlib.loads(c.string_at(xml, size.value))
    finally:
        if xml:
            memory_free(xml)
        if node:
            plist_free(node)


# 参数必须显式指定目标；账号、设备标识和签名团队不写入源码。
def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--udid", required=True)
    parser.add_argument("--bundle-id", required=True)
    args = parser.parse_args()
    if not args.bundle_id.endswith("com.miolib.reader"):
        parser.error("仅允许访问 MioLib 的文件共享区")
    device, house, afc = ptr(), ptr(), ptr()
    sample = Path(__file__).resolve().parents[1] / "Packages/MioLibCore/Tests/MioLibCoreTests/Fixtures/中文样书.txt"
    data = sample.read_bytes()
    filename = f"MioLib_中文验收样书_{uuid.uuid4().hex[:8]}.txt"
    try:
        # VendDocuments 复用苹果文件共享服务，访问范围限制在本应用传输区。
        checked(device_new(c.byref(device), args.udid.encode()), "连接设备")
        checked(house_start(device, c.byref(house), b"MioLib-smoke"), "启动文件共享")
        checked(house_send(house, b"VendDocuments", args.bundle_id.encode()), "打开 MioLib")
        result = response(house)
        if result.get("Error"):
            raise RuntimeError(f"MioLib 文件共享: {result['Error']}")
        checked(afc_new(house, c.byref(afc)), "创建传输通道")

        # 不同服务版本的共享根目录不同；只探测 Documents，不枚举其他文件。
        info = char_array()
        status = file_info(afc, b"/Documents", c.byref(info))
        if info:
            dictionary_free(info)
        if status not in (0, 8):
            checked(status, "确认传输目录")
        remote = (("/Documents/" if status == 0 else "/") + filename).encode("utf-8")

        # 使用随机文件名避免覆盖；分块写入并检查每次实际写入字节数。
        handle = u64()
        checked(file_open(afc, remote, 3, c.byref(handle)), "创建样书")
        try:
            offset = 0
            while offset < len(data):
                part = data[offset:offset + 65536]
                written = u32()
                checked(file_write(afc, handle, part, len(part), c.byref(written)), "传入样书")
                if not written.value:
                    raise RuntimeError("传输未取得进展")
                offset += written.value
        finally:
            checked(file_close(afc, handle), "关闭写入文件")

        # 重新以只读模式打开，确认设备上的样书与项目测试样本完全一致。
        checked(file_open(afc, remote, 1, c.byref(handle)), "读回样书")
        try:
            buffer, count = c.create_string_buffer(len(data) + 1), u32()
            checked(file_read(afc, handle, buffer, len(buffer), c.byref(count)), "校验样书")
            if buffer.raw[:count.value] != data:
                raise RuntimeError("设备样书与原始样本不一致")
        finally:
            checked(file_close(afc, handle), "关闭校验文件")
        print(json.dumps({"file": filename, "bytes": len(data), "sha256": hashlib.sha256(data).hexdigest(), "readback": "passed"}, ensure_ascii=False))
    finally:
        # AFC 借用 House Arrest 连接，必须先释放 AFC 再释放共享服务。
        if afc:
            afc_free(afc)
        if house:
            house_free(house)
        if device:
            device_free(device)


# 命令行运行时才连接设备，导入该模块不会创建或修改手机上的文件。
if __name__ == "__main__":
    main()
