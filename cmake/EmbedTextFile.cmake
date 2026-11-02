# Embeds a text file as `inline constexpr std::string_view <variable>` in <variable>.inc, so a staged program needs no data file.
function(
  kataglyphis_embed_text_file
  target_name
  source_file
  variable)
  set(_kataglyphis_embed_dir "${CMAKE_CURRENT_BINARY_DIR}/generated")
  file(READ "${source_file}" KATAGLYPHIS_EMBEDDED_CONTENT)
  set(KATAGLYPHIS_EMBEDDED_VARIABLE "${variable}")
  file(
    CONFIGURE
    OUTPUT
    "${_kataglyphis_embed_dir}/${variable}.inc"
    CONTENT
    "inline constexpr std::string_view @KATAGLYPHIS_EMBEDDED_VARIABLE@ = R\"kgembed(@KATAGLYPHIS_EMBEDDED_CONTENT@)kgembed\";\n"
    @ONLY)
  set_property(
    DIRECTORY
    APPEND
    PROPERTY CMAKE_CONFIGURE_DEPENDS "${source_file}")
  target_include_directories(${target_name} PRIVATE "${_kataglyphis_embed_dir}")
endfunction()
