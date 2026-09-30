# duktape 2.7.0, the JavaScript engine of mysql_server_mock (component tests).
#
# Restored from mysql-server history (removed upstream in 214f378700f,
# Bug#37009228); only the sources upstream built. Static here, so no DLL
# export handling is needed on Windows.

SET(DUKTAPE_SOURCE_DIR ${CMAKE_CURRENT_SOURCE_DIR}/duktape-2.7.0)

ADD_LIBRARY(duktape STATIC
  ${DUKTAPE_SOURCE_DIR}/src/duktape.c
  ${DUKTAPE_SOURCE_DIR}/extras/logging/duk_logging.c
  ${DUKTAPE_SOURCE_DIR}/extras/module-node/duk_module_node.c)

TARGET_INCLUDE_DIRECTORIES(duktape SYSTEM PUBLIC
  ${DUKTAPE_SOURCE_DIR}/src
  ${DUKTAPE_SOURCE_DIR}/extras/logging
  ${DUKTAPE_SOURCE_DIR}/extras/module-node)

SET_TARGET_PROPERTIES(duktape PROPERTIES POSITION_INDEPENDENT_CODE ON)

IF(MSVC)
  TARGET_COMPILE_OPTIONS(duktape PRIVATE /w)
ELSE()
  TARGET_COMPILE_OPTIONS(duktape PRIVATE -w)
  IF(NOT APPLE)
    TARGET_LINK_LIBRARIES(duktape PUBLIC m)
  ENDIF()
ENDIF()
