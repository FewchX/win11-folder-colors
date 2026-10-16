// FolderColorMenu.dll - "Folder color" in the Windows 11 context menu.
//
// The new Windows 11 menu only shows IExplorerCommand handlers that come
// from a package, so this DLL is registered through AppxManifest.xml (see
// install.ps1) and Explorer loads it in a COM surrogate. It only builds the
// menu: every item runs FolderColor.exe from the same folder, which does the
// actual work for all selected folders at once.
//
// Labels come from menu.txt next to the DLL (install.ps1 writes it from
// colors.json): first line is the menu title, then "<id>\t<label>" per item;
// the id "reset" is the stock-icon item.
//
// Build: build.ps1 (zig c++ from the ziglang Python package).

#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <shobjidl.h>
#include <shlwapi.h>
#include <new>
#include <string>
#include <vector>

// {D29F5EDC-9191-4EB2-BCE9-7D761D399A80} - also in AppxManifest.xml
static const CLSID kClsidFolderColorMenu = {0xd29f5edc, 0x9191, 0x4eb2, {0xbc, 0xe9, 0x7d, 0x76, 0x1d, 0x39, 0x9a, 0x80}};

// defined locally so the build doesn't depend on libuuid
static const IID kIidUnknown = {0x00000000, 0x0000, 0x0000, {0xc0, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x46}};
static const IID kIidClassFactory = {0x00000001, 0x0000, 0x0000, {0xc0, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x46}};
static const IID kIidExplorerCommand = {0xa08ce4d0, 0xfa25, 0x44ab, {0xb5, 0x7c, 0xc7, 0xb1, 0xc3, 0x23, 0xe0, 0xb9}};
static const IID kIidEnumExplorerCommand = {0xa88826f8, 0x186f, 0x4987, {0xaa, 0xde, 0xea, 0x0c, 0xef, 0x8f, 0xbf, 0xe8}};

static HMODULE g_module;
static LONG g_objects; // live objects + server locks, for DllCanUnloadNow

static std::wstring ModuleDir() {
    wchar_t buf[4096];
    DWORD n = GetModuleFileNameW(g_module, buf, ARRAYSIZE(buf));
    std::wstring path(buf, n);
    return path.substr(0, path.find_last_of(L'\\'));
}

struct MenuEntry {
    std::wstring id, label;
};

struct MenuSpec {
    std::wstring title = L"Folder color";
    std::vector<MenuEntry> items;
};

static MenuSpec LoadMenu() {
    MenuSpec spec;
    std::wstring path = ModuleDir() + L"\\menu.txt";
    HANDLE f = CreateFileW(path.c_str(), GENERIC_READ, FILE_SHARE_READ, nullptr, OPEN_EXISTING, 0, nullptr);
    if (f == INVALID_HANDLE_VALUE) return spec;
    DWORD size = GetFileSize(f, nullptr), read = 0;
    std::string bytes(size, '\0');
    ReadFile(f, &bytes[0], size, &read, nullptr);
    CloseHandle(f);
    bytes.resize(read);
    if (bytes.size() >= 3 && bytes.compare(0, 3, "\xEF\xBB\xBF") == 0) bytes.erase(0, 3);

    int wlen = MultiByteToWideChar(CP_UTF8, 0, bytes.data(), (int)bytes.size(), nullptr, 0);
    std::wstring text(wlen, L'\0');
    MultiByteToWideChar(CP_UTF8, 0, bytes.data(), (int)bytes.size(), &text[0], wlen);

    bool first = true;
    size_t pos = 0;
    while (pos < text.size()) {
        size_t end = text.find(L'\n', pos);
        if (end == std::wstring::npos) end = text.size();
        std::wstring line = text.substr(pos, end - pos);
        pos = end + 1;
        if (!line.empty() && line.back() == L'\r') line.pop_back();
        if (line.empty()) continue;
        if (first) {
            spec.title = line;
            first = false;
            continue;
        }
        size_t tab = line.find(L'\t');
        if (tab != std::wstring::npos) spec.items.push_back({line.substr(0, tab), line.substr(tab + 1)});
    }
    return spec;
}

// --- shared IUnknown / IExplorerCommand plumbing ------------------------------

class CommandBase : public IExplorerCommand {
public:
    CommandBase() { InterlockedIncrement(&g_objects); }
    virtual ~CommandBase() { InterlockedDecrement(&g_objects); }

    IFACEMETHODIMP QueryInterface(REFIID riid, void **ppv) override {
        if (!ppv) return E_POINTER;
        if (IsEqualIID(riid, kIidUnknown) || IsEqualIID(riid, kIidExplorerCommand)) {
            *ppv = static_cast<IExplorerCommand *>(this);
            AddRef();
            return S_OK;
        }
        *ppv = nullptr;
        return E_NOINTERFACE;
    }
    IFACEMETHODIMP_(ULONG) AddRef() override { return InterlockedIncrement(&refs_); }
    IFACEMETHODIMP_(ULONG) Release() override {
        LONG r = InterlockedDecrement(&refs_);
        if (r == 0) delete this;
        return r;
    }

    IFACEMETHODIMP GetToolTip(IShellItemArray *, LPWSTR *tip) override {
        *tip = nullptr;
        return E_NOTIMPL;
    }
    IFACEMETHODIMP GetCanonicalName(GUID *guid) override {
        *guid = GUID_NULL;
        return S_OK;
    }
    IFACEMETHODIMP GetState(IShellItemArray *, BOOL, EXPCMDSTATE *state) override {
        *state = ECS_ENABLED;
        return S_OK;
    }

private:
    LONG refs_ = 1;
};

// --- one color (or reset) ---------------------------------------------------------

class ColorCommand final : public CommandBase {
public:
    ColorCommand(const MenuEntry &entry, const std::wstring &dir)
        : id_(entry.id), label_(entry.label), dir_(dir) {}

    IFACEMETHODIMP GetTitle(IShellItemArray *, LPWSTR *name) override { return SHStrDupW(label_.c_str(), name); }

    IFACEMETHODIMP GetIcon(IShellItemArray *, LPWSTR *icon) override {
        if (id_ != L"reset") return SHStrDupW((dir_ + L"\\icons\\" + id_ + L".ico").c_str(), icon);
        wchar_t stock[MAX_PATH];
        ExpandEnvironmentStringsW(L"%SystemRoot%\\System32\\imageres.dll,-3", stock, MAX_PATH);
        return SHStrDupW(stock, icon);
    }

    IFACEMETHODIMP GetFlags(EXPCMDFLAGS *flags) override {
        *flags = id_ == L"reset" ? ECF_SEPARATORBEFORE : ECF_DEFAULT;
        return S_OK;
    }

    IFACEMETHODIMP EnumSubCommands(IEnumExplorerCommand **e) override {
        *e = nullptr;
        return E_NOTIMPL;
    }

    IFACEMETHODIMP Invoke(IShellItemArray *items, IBindCtx *) override {
        if (!items) return E_INVALIDARG;
        std::wstring cmd = L"\"" + dir_ + L"\\FolderColor.exe\" " + (id_ == L"reset" ? L"reset" : L"set " + id_);
        DWORD count = 0;
        items->GetCount(&count);
        for (DWORD i = 0; i < count; i++) {
            IShellItem *item = nullptr;
            if (FAILED(items->GetItemAt(i, &item))) continue;
            LPWSTR path = nullptr;
            if (SUCCEEDED(item->GetDisplayName(SIGDN_FILESYSPATH, &path))) {
                std::wstring p(path);
                // a trailing backslash would escape the closing quote
                if (!p.empty() && p.back() == L'\\') p += L'\\';
                cmd += L" \"" + p + L"\"";
                CoTaskMemFree(path);
            }
            item->Release();
        }

        std::vector<wchar_t> line(cmd.begin(), cmd.end());
        line.push_back(L'\0');
        STARTUPINFOW si = {};
        si.cb = sizeof si;
        PROCESS_INFORMATION pi = {};
        if (!CreateProcessW(nullptr, line.data(), nullptr, nullptr, FALSE, 0, nullptr, nullptr, &si, &pi))
            return HRESULT_FROM_WIN32(GetLastError());
        CloseHandle(pi.hThread);
        CloseHandle(pi.hProcess);
        return S_OK;
    }

private:
    std::wstring id_, label_, dir_;
};

// --- submenu enumerator ----------------------------------------------------------

class CommandEnum final : public IEnumExplorerCommand {
public:
    explicit CommandEnum(std::vector<IExplorerCommand *> commands) : commands_(std::move(commands)) {
        InterlockedIncrement(&g_objects);
    }
    ~CommandEnum() {
        for (IExplorerCommand *c : commands_) c->Release();
        InterlockedDecrement(&g_objects);
    }

    IFACEMETHODIMP QueryInterface(REFIID riid, void **ppv) override {
        if (!ppv) return E_POINTER;
        if (IsEqualIID(riid, kIidUnknown) || IsEqualIID(riid, kIidEnumExplorerCommand)) {
            *ppv = static_cast<IEnumExplorerCommand *>(this);
            AddRef();
            return S_OK;
        }
        *ppv = nullptr;
        return E_NOINTERFACE;
    }
    IFACEMETHODIMP_(ULONG) AddRef() override { return InterlockedIncrement(&refs_); }
    IFACEMETHODIMP_(ULONG) Release() override {
        LONG r = InterlockedDecrement(&refs_);
        if (r == 0) delete this;
        return r;
    }

    IFACEMETHODIMP Next(ULONG wanted, IExplorerCommand **out, ULONG *fetched) override {
        ULONG n = 0;
        while (n < wanted && pos_ < commands_.size()) {
            out[n] = commands_[pos_++];
            out[n]->AddRef();
            n++;
        }
        if (fetched) *fetched = n;
        return n == wanted ? S_OK : S_FALSE;
    }
    IFACEMETHODIMP Skip(ULONG count) override {
        pos_ = (pos_ + count < commands_.size()) ? pos_ + count : commands_.size();
        return pos_ < commands_.size() ? S_OK : S_FALSE;
    }
    IFACEMETHODIMP Reset() override {
        pos_ = 0;
        return S_OK;
    }
    IFACEMETHODIMP Clone(IEnumExplorerCommand **e) override {
        *e = nullptr;
        return E_NOTIMPL;
    }

private:
    LONG refs_ = 1;
    std::vector<IExplorerCommand *> commands_;
    size_t pos_ = 0;
};

// --- top-level "Folder color" --------------------------------------------------

class RootCommand final : public CommandBase {
public:
    RootCommand() : dir_(ModuleDir()), spec_(LoadMenu()) {}

    IFACEMETHODIMP GetTitle(IShellItemArray *, LPWSTR *name) override { return SHStrDupW(spec_.title.c_str(), name); }
    IFACEMETHODIMP GetIcon(IShellItemArray *, LPWSTR *icon) override {
        return SHStrDupW((dir_ + L"\\icons\\menu.ico").c_str(), icon);
    }
    IFACEMETHODIMP GetFlags(EXPCMDFLAGS *flags) override {
        *flags = ECF_HASSUBCOMMANDS;
        return S_OK;
    }
    IFACEMETHODIMP Invoke(IShellItemArray *, IBindCtx *) override { return E_NOTIMPL; }

    IFACEMETHODIMP EnumSubCommands(IEnumExplorerCommand **e) override {
        std::vector<IExplorerCommand *> commands;
        for (const MenuEntry &entry : spec_.items) {
            ColorCommand *c = new (std::nothrow) ColorCommand(entry, dir_);
            if (c) commands.push_back(c);
        }
        *e = new (std::nothrow) CommandEnum(std::move(commands));
        return *e ? S_OK : E_OUTOFMEMORY;
    }

private:
    std::wstring dir_;
    MenuSpec spec_;
};

// --- class factory + exports ---------------------------------------------------

class Factory final : public IClassFactory {
public:
    IFACEMETHODIMP QueryInterface(REFIID riid, void **ppv) override {
        if (!ppv) return E_POINTER;
        if (IsEqualIID(riid, kIidUnknown) || IsEqualIID(riid, kIidClassFactory)) {
            *ppv = static_cast<IClassFactory *>(this);
            return S_OK;
        }
        *ppv = nullptr;
        return E_NOINTERFACE;
    }
    // static instance - no reference counting
    IFACEMETHODIMP_(ULONG) AddRef() override { return 2; }
    IFACEMETHODIMP_(ULONG) Release() override { return 1; }

    IFACEMETHODIMP CreateInstance(IUnknown *outer, REFIID riid, void **ppv) override {
        if (outer) return CLASS_E_NOAGGREGATION;
        RootCommand *root = new (std::nothrow) RootCommand();
        if (!root) return E_OUTOFMEMORY;
        HRESULT hr = root->QueryInterface(riid, ppv);
        root->Release();
        return hr;
    }
    IFACEMETHODIMP LockServer(BOOL lock) override {
        if (lock) InterlockedIncrement(&g_objects);
        else InterlockedDecrement(&g_objects);
        return S_OK;
    }
};

static Factory g_factory;

extern "C" BOOL WINAPI DllMain(HINSTANCE instance, DWORD reason, LPVOID) {
    if (reason == DLL_PROCESS_ATTACH) {
        g_module = instance;
        DisableThreadLibraryCalls(instance);
    }
    return TRUE;
}

STDAPI DllGetClassObject(REFCLSID clsid, REFIID riid, LPVOID *ppv) {
    if (!ppv) return E_POINTER;
    *ppv = nullptr;
    if (!IsEqualCLSID(clsid, kClsidFolderColorMenu)) return CLASS_E_CLASSNOTAVAILABLE;
    return g_factory.QueryInterface(riid, ppv);
}

STDAPI DllCanUnloadNow() {
    return g_objects == 0 ? S_OK : S_FALSE;
}
