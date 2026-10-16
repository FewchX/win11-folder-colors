// menu-harness: drives FolderColorMenu.dll the way File Explorer does, for
// tests\run-menu-tests.ps1 and tests\run-install-tests.ps1. Built by
// build.ps1 -Tests into tests\bin\<arch>\menu-harness.exe.
//
//   menu-harness <dll> | com  describe <folder>
//   menu-harness <dll> | com  state <item>...
//   menu-harness <dll> | com  invoke <label> <item>...
//
// <dll> loads that FolderColorMenu.dll directly; "com" asks COM for the class
// instead, which only the installed package provides (in its surrogate, like
// for File Explorer). An <item> is what File Explorer would parse: a path, or
// ::{CLSID} for a virtual folder; @file reads one per line from a UTF-8 file.
//
// Prints UTF-8 lines:
//   describe  "root|item <TAB> title <TAB> icon <TAB> flags" (flags in hex)
//   state     "ENABLED" or "HIDDEN", for all the items together
//   invoke    "invoked <hresult>"
// and "error <what> <hresult>" with exit code 1 when something fails.
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <shlobj.h>
#include <shobjidl.h>
#include <cstdio>
#include <cwchar>
#include <string>
#include <vector>

static const CLSID kClsid = {0xd29f5edc, 0x9191, 0x4eb2, {0xbc, 0xe9, 0x7d, 0x76, 0x1d, 0x39, 0x9a, 0x80}};
static const IID kIClassFactory = {0x00000001, 0x0000, 0x0000, {0xc0, 0, 0, 0, 0, 0, 0, 0x46}};
static const IID kIExplorerCommand = {0xa08ce4d0, 0xfa25, 0x44ab, {0xb5, 0x7c, 0xc7, 0xb1, 0xc3, 0x23, 0xe0, 0xb9}};

typedef HRESULT(WINAPI *GetClassObjectFn)(REFCLSID, REFIID, void **);

static void Print(const std::wstring &line) {
    std::wstring s = line + L"\n";
    int n = WideCharToMultiByte(CP_UTF8, 0, s.c_str(), (int)s.size(), nullptr, 0, nullptr, nullptr);
    std::string bytes(n, '\0');
    WideCharToMultiByte(CP_UTF8, 0, s.c_str(), (int)s.size(), &bytes[0], n, nullptr, nullptr);
    fwrite(bytes.data(), 1, bytes.size(), stdout);
    fflush(stdout);
}

static std::wstring Hex(unsigned long value) {
    wchar_t buf[16];
    swprintf(buf, 16, L"%08lx", value);
    return buf;
}

static int Fail(const std::wstring &what, HRESULT hr) {
    Print(L"error " + what + L" " + Hex((unsigned long)hr));
    return 1;
}

static HRESULT CreateRoot(const wchar_t *source, IExplorerCommand **root) {
    if (wcscmp(source, L"com") == 0)
        return CoCreateInstance(kClsid, nullptr, CLSCTX_LOCAL_SERVER, kIExplorerCommand, (void **)root);
    HMODULE module = LoadLibraryW(source);
    if (!module) return HRESULT_FROM_WIN32(GetLastError());
    auto getClassObject = (GetClassObjectFn)(void *)GetProcAddress(module, "DllGetClassObject");
    if (!getClassObject) return HRESULT_FROM_WIN32(GetLastError());
    IClassFactory *factory = nullptr;
    HRESULT hr = getClassObject(kClsid, kIClassFactory, (void **)&factory);
    if (FAILED(hr)) return hr;
    hr = factory->CreateInstance(nullptr, kIExplorerCommand, (void **)root);
    factory->Release();
    return hr;
}

// arguments, with each @file replaced by its lines
static bool ReadItems(int first, int argc, wchar_t **argv, std::vector<std::wstring> &items) {
    for (int i = first; i < argc; i++) {
        if (argv[i][0] != L'@') {
            items.push_back(argv[i]);
            continue;
        }
        HANDLE file = CreateFileW(argv[i] + 1, GENERIC_READ, FILE_SHARE_READ, nullptr, OPEN_EXISTING, 0, nullptr);
        if (file == INVALID_HANDLE_VALUE) return false;
        std::string bytes(GetFileSize(file, nullptr), '\0');
        DWORD got = 0;
        BOOL ok = bytes.empty() || ReadFile(file, &bytes[0], (DWORD)bytes.size(), &got, nullptr);
        CloseHandle(file);
        if (!ok) return false;
        if (bytes.compare(0, 3, "\xEF\xBB\xBF") == 0) bytes.erase(0, 3);
        int n = MultiByteToWideChar(CP_UTF8, 0, bytes.data(), (int)bytes.size(), nullptr, 0);
        std::wstring text(n, L'\0');
        MultiByteToWideChar(CP_UTF8, 0, bytes.data(), (int)bytes.size(), &text[0], n);
        size_t start = 0;
        while (start < text.size()) {
            size_t end = text.find(L'\n', start);
            if (end == std::wstring::npos) end = text.size();
            std::wstring line = text.substr(start, end - start);
            if (!line.empty() && line.back() == L'\r') line.pop_back();
            if (!line.empty()) items.push_back(line);
            start = end + 1;
        }
    }
    return true;
}

static HRESULT ArrayOf(const std::vector<std::wstring> &items, IShellItemArray **array) {
    std::vector<PIDLIST_ABSOLUTE> pidls;
    HRESULT hr = S_OK;
    for (const std::wstring &item : items) {
        PIDLIST_ABSOLUTE pidl = nullptr;
        hr = SHParseDisplayName(item.c_str(), nullptr, &pidl, 0, nullptr);
        if (FAILED(hr)) {
            Print(L"error parsing " + item + L" " + Hex((unsigned long)hr));
            break;
        }
        pidls.push_back(pidl);
    }
    if (SUCCEEDED(hr)) hr = SHCreateShellItemArrayFromIDLists((UINT)pidls.size(), (PCIDLIST_ABSOLUTE_ARRAY)pidls.data(), array);
    for (PIDLIST_ABSOLUTE pidl : pidls) CoTaskMemFree(pidl);
    return hr;
}

static std::wstring Describe(const wchar_t *kind, IExplorerCommand *command, IShellItemArray *array) {
    LPWSTR title = nullptr, icon = nullptr;
    EXPCMDFLAGS flags = 0;
    command->GetTitle(array, &title);
    command->GetIcon(array, &icon);
    command->GetFlags(&flags);
    std::wstring line = std::wstring(kind) + L"\t" + (title ? title : L"") + L"\t" + (icon ? icon : L"") + L"\t" + Hex(flags);
    CoTaskMemFree(title);
    CoTaskMemFree(icon);
    return line;
}

static int Run(int argc, wchar_t **argv) {
    if (argc < 4) {
        Print(L"usage: menu-harness <dll>|com describe|state|invoke [label] <item>...");
        return 2;
    }
    const wchar_t *action = argv[2];
    bool invoke = wcscmp(action, L"invoke") == 0;
    std::vector<std::wstring> items;
    if (!ReadItems(invoke ? 4 : 3, argc, argv, items) || items.empty()) return Fail(L"reading the items", E_INVALIDARG);

    IExplorerCommand *root = nullptr;
    HRESULT hr = CreateRoot(argv[1], &root);
    if (FAILED(hr)) return Fail(L"creating the command", hr);
    IShellItemArray *array = nullptr;
    hr = ArrayOf(items, &array);
    if (FAILED(hr)) return Fail(L"making the selection", hr);

    if (wcscmp(action, L"state") == 0) {
        EXPCMDSTATE state = 0;
        hr = root->GetState(array, TRUE, &state);
        if (FAILED(hr)) return Fail(L"GetState", hr);
        Print(state == ECS_ENABLED ? L"ENABLED" : state == ECS_HIDDEN ? L"HIDDEN" : Hex(state));
        return 0;
    }

    bool describe = wcscmp(action, L"describe") == 0;
    if (!describe && !invoke) return Fail(L"unknown action", E_INVALIDARG);
    if (describe) Print(Describe(L"root", root, array));
    IEnumExplorerCommand *commands = nullptr;
    hr = root->EnumSubCommands(&commands);
    if (FAILED(hr)) return Fail(L"EnumSubCommands", hr);
    bool found = false;
    IExplorerCommand *command = nullptr;
    ULONG got = 0;
    while (commands->Next(1, &command, &got) == S_OK && got == 1) {
        if (describe) Print(Describe(L"item", command, array));
        LPWSTR title = nullptr;
        if (invoke && !found && SUCCEEDED(command->GetTitle(array, &title)) && wcscmp(title, argv[3]) == 0) {
            found = true;
            hr = command->Invoke(array, nullptr);
            Print(L"invoked " + Hex((unsigned long)hr));
        }
        CoTaskMemFree(title);
        command->Release();
    }
    commands->Release();
    array->Release();
    root->Release();
    if (invoke && !found) return Fail(L"no item is called " + std::wstring(argv[3]), E_INVALIDARG);
    return invoke && FAILED(hr) ? 1 : 0;
}

int wmain(int argc, wchar_t **argv) {
    CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);
    int code = Run(argc, argv);
    CoUninitialize();
    return code;
}
