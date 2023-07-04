local PRIVATE_MARKER = newproxy() -- only the class and inherited class can access it
local PROTECTED_MARKER = newproxy() -- only the class and inherited can read and write; will only be read-only for other sources
local INHERITED_MARKER = newproxy()
local INHERITS_MARKER = newproxy()
local STRICTIFIY_VALUE_MARKER = newproxy()
local INTERNAL_MARKER = newproxy()
local LOCKED_MARKER = newproxy() -- cant change after runtime fr

local EXPLICIT_PRIVATE_PREFIX = "_"
local EXPLICIT_PROTECTED_PREFIX = "__"

local READ_PRIVATE_NO_ACCESS = "Attempted to read private \"%s\""
local READ_INTERNAL_FAILED = "Cannot read internal property \"%s\""
local WRITE_PRIVATE_NO_ACCESS = "Attempted to write private \"%s\" with the value \"%s\""
local WRITE_PROTECTED_NO_ACCESS = "Attempted to write protected \"%s\" with the value \"%s\""
local WRITE_INTERNAL_FAILED = "Cannot write internal property \"%s\""
local CANNOT_WRITE_CONSTANT = "Attempted to overwrite constant \"%s\""
local CANNOT_WRITE_LOCKED = "Attempt to overwrite locked property \"%s\""

local EMPTY_STRING = ''

local function hasFunction(class, method)
	for _, fn in pairs(class) do
		if type(fn) == "function" and fn == method then
			return true
		end
	end
	return false
end

local function canAccessViaInheritance(class, method)
	for inherited in pairs(class[INHERITED_MARKER]) do
		if inherited[INHERITS_MARKER][class] ~= nil and hasFunction(inherited, method) then
			return true
		end
	end
	return false
end

local function isWithinClassScope(class, includeInherited)
	local level = 1--skip  __index
	local within = false
	local calledWithinFunction = false
	while true do
		level += 1
		local method = debug.info(level, 'f')
		local _, fnName = pcall(debug.info, method, 'n') -- anonymous and c-functions will return nil and prolly error?
		if fnName == EMPTY_STRING then
			break
		end
		
		if hasFunction(class, method) then
			calledWithinFunction = true
		end

		local result = (class[fnName] == method or calledWithinFunction) or (if includeInherited then canAccessViaInheritance(class, method) else false)
		if result then
			within = true
			break
		end
	end
	return within
end

local function isSpecialKey(key)
	return type(key) == "userdata"
end

local function isAConstant(str: string)
	if isSpecialKey(str) then return false end
	str = str:gsub('_', '') -- remove underscores
	local compare = str:gsub('(%l)', '')
	return #compare == #str
end

local function isAccessingInternal(key)
	return not isSpecialKey(key) and key:sub(1, 2) == EXPLICIT_PROTECTED_PREFIX and key:sub(#key - #EXPLICIT_PROTECTED_PREFIX+1) == EXPLICIT_PROTECTED_PREFIX
end

local function isAccessingProtected(key)
	return not isSpecialKey(key) and key:sub(1, 2) == EXPLICIT_PROTECTED_PREFIX and key:sub(#key - #EXPLICIT_PROTECTED_PREFIX) ~= EXPLICIT_PROTECTED_PREFIX
end

local function isAccessingPrivate(key)
	return not isSpecialKey(key) and key:sub(1, 2) ~= EXPLICIT_PROTECTED_PREFIX and key:sub(#key - #EXPLICIT_PROTECTED_PREFIX) ~= EXPLICIT_PROTECTED_PREFIX and key:sub(1, 1) == EXPLICIT_PRIVATE_PREFIX
end

local function initSelf(defaultProps)
	local self = if type(defaultProps) == "table" then table.clone(defaultProps) else {}
	self[PRIVATE_MARKER] = {}
	self[PROTECTED_MARKER] = {}
	self[LOCKED_MARKER] = {}
	self[INTERNAL_MARKER] = {}
	self[STRICTIFIY_VALUE_MARKER] = {}
	return self
end

local function Class(defaultProps: {}?)
	local meta = {}
	local class = {}
	class[INHERITS_MARKER] = {}
	class[INHERITED_MARKER] = {}

	function meta:__index(key)
		local canAccessPrivate, canAccessInternal = isWithinClassScope(class, true), isWithinClassScope(class, false)
		if isAccessingInternal(key) and not canAccessInternal then
			error(string.format(READ_INTERNAL_FAILED, key), 2)
		elseif isAccessingPrivate(key) and not canAccessPrivate then
			error(string.format(READ_PRIVATE_NO_ACCESS, key), 2)
		end

		local public = rawget(self, key)
		local protected = rawget(self, PROTECTED_MARKER)
		if canAccessPrivate or canAccessInternal then
			return rawget(self, INTERNAL_MARKER)[key] or rawget(self, PRIVATE_MARKER)[key] or protected[key] or public or class[key]
		end
		return protected[key] or public or class[key]
	end

	function meta:__newindex(key, value)
		local accessingPrivate, accessingProtected, accessingLocked, accessingInternal = isAccessingPrivate(key), isAccessingProtected(key), rawget(self, LOCKED_MARKER)[key], isAccessingInternal(key)
		if accessingLocked then
			error(string.format(
				if isAConstant(key) then CANNOT_WRITE_CONSTANT else CANNOT_WRITE_LOCKED,
				key), 2)
		elseif accessingInternal and not isWithinClassScope(class, false) then
			error(string.format(WRITE_INTERNAL_FAILED, key), 3)
		elseif (accessingPrivate or accessingProtected) and not isWithinClassScope(class, true) then
			error(string.format(
				if accessingPrivate then WRITE_PRIVATE_NO_ACCESS else WRITE_PROTECTED_NO_ACCESS,
				tostring(key), tostring(value)), 2)
		else
			local predicate = rawget(self, STRICTIFIY_VALUE_MARKER)[key]
			if predicate ~= nil then
				local ok, err = predicate(value)
				if not ok then
					error(err or "Failed to set strict property", 2)
				end
			end

			if accessingPrivate then
				rawget(self, PRIVATE_MARKER)[key] = value
			elseif accessingProtected then
				rawget(self, PROTECTED_MARKER)[key] = value
			else
				if key == PROTECTED_MARKER or key == PRIVATE_MARKER then
					error("Cannot override internal properties", 3)
				end
				rawset(self, key, value)
			end
		end
	end

	function class.new(...)
		local self = setmetatable(initSelf(defaultProps), meta)
		if self.__init then
			self:__init(...)
		end

		-- now check the constants
		for key, value in pairs(self) do
			if isAConstant(key) and type(value) ~= "function" then
				self[LOCKED_MARKER][key] = true
			end
		end

		return self
	end

	function class.inherits(otherClass)
		assert(otherClass[INHERITED_MARKER] ~= nil, "Cannot inherit from an unrelated class or table")
		class[INHERITS_MARKER][otherClass] = true
		otherClass[INHERITED_MARKER][class] = true
	end

	function class.extend()
		local subClass = Class()
		setmetatable(subClass, {__index = class})
		return subClass
	end

	function class:__strictifyProperty(propName: string, predicate: (value: any) -> boolean)
		self[STRICTIFIY_VALUE_MARKER][propName] = predicate
	end

	function class:__lockProperty(propName: string)
		self[LOCKED_MARKER][propName] = true
	end

	function class:__unlockProperty(propName: string)
		assert(not isAConstant(propName), "Cannot unlock a constant!")
		self[LOCKED_MARKER][propName] = true
	end

	return class
end

return Class