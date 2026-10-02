variable "mandatory_tags" {
  description = "Tag names that must exist on every resource"
  type        = list(string)
}

variable "allowed_locations" {
  description = "Azure regions resources may be deployed into"
  type        = list(string)
}
