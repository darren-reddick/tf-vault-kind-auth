resource "aws_dynamodb_table" "user_table" {

  name         = "${local.prefix}-Table"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "userid"


  attribute {
    name = "userid"
    type = "S"
  }

  tags = {
    Name = "${local.prefix}-Table"
  }

}

resource "aws_dynamodb_table_item" "example" {
  table_name = aws_dynamodb_table.user_table.name
  hash_key   = aws_dynamodb_table.user_table.hash_key

  item = <<ITEM
{
  "userid": {"S": "1234"},
  "name": {"S": "Dave"}
}
ITEM
}