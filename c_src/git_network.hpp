#pragma once
//------------------------------------------------------------------------------
// What clone, fetch and push share beyond credentials (git_credentials.hpp):
// extra HTTP headers, and what a push reports per ref.
//------------------------------------------------------------------------------

#include <string>
#include <string_view>
#include <utility>
#include <vector>

/**
 * The `headers` option, `[<<"Name: value">>, ...]`, as libgit2's
 * `custom_headers`. libgit2 only keeps the pointers for the duration of
 * the call: this owns the strings until then.
 *
 * libgit2 checks the headers themselves when it uses them: a malformed one,
 * or one it sets itself (Host, User-Agent, Content-Type...), fails the
 * operation with its message.
 */
struct CustomHeaders {
  std::vector<std::string> values;
  std::vector<char*>       ptrs;

  git_strarray array() {
    ptrs.clear();
    for (auto& v : values)
      ptrs.push_back(v.data());

    return git_strarray{
      .strings = ptrs.empty() ? nullptr : ptrs.data(),
      .count   = ptrs.size()
    };
  }
};

/**
 * Reads the `headers` option of `opts` into `out`. Options that are not a
 * map, or have no `headers`, have none. False when `headers` is not a list
 * of non-empty binaries.
 */
inline bool parse_headers(ErlNifEnv* env, ERL_NIF_TERM opts, CustomHeaders& out)
{
  ERL_NIF_TERM list;

  if (!opts || !enif_is_map(env, opts) || !enif_get_map_value(env, opts, ATOM_HEADERS, &list))
    return true;

  ERL_NIF_TERM head;
  ErlNifBinary bin;

  while (enif_get_list_cell(env, list, &head, &list)) {
    if (!enif_inspect_binary(env, head, &bin) || bin.size == 0)
      return false;
    out.values.push_back(bin_to_str(bin));
  }

  return enif_is_empty_list(env, list);
}

/**
 * What a push reports, through its callbacks' payload: the refs the server
 * refused, with its reason (`ng <ref> <reason>` in its report-status), and
 * the text it sent on the side band, its `remote:` lines (a pre-receive
 * hook's message, for instance).
 *
 * libgit2's git_remote_push succeeds when the server refuses refs: only the
 * push_update_reference callback tells.
 */
struct PushReport {
  std::vector<std::pair<std::string, std::string>> rejected;
  std::string                                      progress;

  static int update_reference(const char* refname, const char* status, void* payload)
  {
    if (status)
      static_cast<PushReport*>(payload)->rejected.emplace_back(refname, status);
    return 0;
  }

  static int sideband_progress(const char* str, int len, void* payload)
  {
    static_cast<PushReport*>(payload)->progress.append(str, len);
    return 0;
  }

  void install(git_remote_callbacks& callbacks)
  {
    callbacks.push_update_reference = update_reference;
    callbacks.sideband_progress     = sideband_progress;
    callbacks.payload               = this;
  }

  /**
   * The side band's lines, as a terminal would show them: a `\r` (progress
   * redrawn in place) keeps only what follows it; trailing blanks (git pads
   * its lines) and empty lines are dropped.
   */
  std::vector<std::string> lines() const
  {
    std::vector<std::string> out;
    std::string_view text(progress);

    while (!text.empty()) {
      auto end  = text.find('\n');
      auto line = text.substr(0, end);
      text      = end == std::string_view::npos ? std::string_view() : text.substr(end + 1);

      if (auto cr = line.find_last_of('\r'); cr != std::string_view::npos) {
        // "...\r" ending a line: what was drawn before it.
        if (cr + 1 == line.size()) {
          line = line.substr(0, cr);
          cr   = line.find_last_of('\r');
        }
        if (cr != std::string_view::npos)
          line = line.substr(cr + 1);
      }

      auto last = line.find_last_not_of(" \t");
      if (last != std::string_view::npos)
        out.emplace_back(line.substr(0, last + 1));
    }

    return out;
  }

  /** `{error, {rejected, [{Ref, Reason}], [Line]}}` */
  ERL_NIF_TERM rejection(ErlNifEnv* env) const
  {
    std::vector<ERL_NIF_TERM> refs, messages;

    for (auto& [ref, reason] : rejected)
      refs.push_back(enif_make_tuple2(env, make_binary(env, ref), make_binary(env, reason)));

    for (auto& line : lines())
      messages.push_back(make_binary(env, line));

    return make_error(env, enif_make_tuple3(env, ATOM_REJECTED,
                                            make_list(env, refs), make_list(env, messages)));
  }
};
