# Embeds a text file as `inline constexpr std::string_view <variable>` in <variable>.inc, so a staged program needs no data file.
function(
  kataglyphis_embed_text_file
  target_name
  source_file
  variable)
  set(_kataglyphis_embed_dir "${CMAKE_CURRENT_BINARY_DIR}/generated")
  kataglyphis_write_embedded_text("${source_file}" ${variable} "${_kataglyphis_embed_dir}/${variable}.inc")
  set_property(
    DIRECTORY
    APPEND
    PROPERTY CMAKE_CONFIGURE_DEPENDS "${source_file}")
  target_include_directories(${target_name} PRIVATE "${_kataglyphis_embed_dir}")
endfunction()

# The include itself, one char per byte: MSVC refuses a string literal over 16380 bytes, a char array has no limit.
function(
  kataglyphis_write_embedded_text
  source_file
  variable
  output_file)
  file(
    READ
    "${source_file}"
    _bytes
    HEX)
  string(
    REGEX
    REPLACE "([0-9a-f][0-9a-f])"
            "'\\\\x\\1',"
            _bytes
            "${_bytes}")
  # A Windows checkout may hold CRLF; every lane embeds the same LF text.
  string(
    REPLACE "'\\x0d','\\x0a',"
            "'\\x0a',"
            _bytes
            "${_bytes}")
  # Sixteen bytes a line; each is written as seven characters.
  string(
    REPEAT
    "."
    112
    _row)
  string(
    REGEX
    REPLACE "(${_row})"
            "\\1\n"
            _bytes
            "${_bytes}")
  file(
    CONFIGURE
    OUTPUT
    "${output_file}"
    CONTENT
    "inline constexpr char @variable@_bytes[] = {\n@_bytes@'\\0' };\ninline constexpr std::string_view @variable@{ @variable@_bytes, sizeof(@variable@_bytes) - 1 };\n"
    @ONLY)
endfunction()
